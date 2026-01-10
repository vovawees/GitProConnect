@tool
extends EditorPlugin
class_name GitProCore

# --- КОНФИГ ---
const USER_CFG = "user://git_pro_auth.cfg"
const PROJ_CFG = "res://addons/git_pro_connect/git_config.cfg"
const BACKUP_EXT = ".bak"
const SYNC_INTERVAL = 60.0 # Проверка обновлений каждые 60 сек

# --- ДАННЫЕ ---
var token = ""
var owner_name = ""
var repo_name = ""
var branch = "main"
var last_known_sha = "" # Последний SHA, который мы видели
var user_data = { "name": "Гость", "login": "", "avatar": null }

# --- СИСТЕМА ---
var http_pool: Array[HTTPRequest] = []
var http_busy: Array[bool] = []
var sync_timer: Timer
var dock: Control

# --- СИГНАЛЫ ---
signal log_msg(text: String, color: Color)
signal progress(step: String, current: int, total: int)
signal state_changed
signal operation_done(success: bool)
signal remote_update_detected # Сигнал, что на сервере что-то новое

func _enter_tree():
	# Пул воркеров
	for i in range(4):
		var r = HTTPRequest.new(); r.timeout = 60.0; r.set_tls_options(TLSOptions.client_unsafe())
		add_child(r); http_pool.append(r); http_busy.append(false)
	
	# Таймер авто-проверки
	sync_timer = Timer.new()
	sync_timer.wait_time = SYNC_INTERVAL
	sync_timer.one_shot = false
	sync_timer.timeout.connect(_check_remote_updates)
	add_child(sync_timer)
	
	_load_cfg()
	
	var ui_res = load("res://addons/git_pro_connect/git_ui.gd")
	if ui_res:
		dock = ui_res.new(self)
		dock.name = "GitPro"
		add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)
		
	await get_tree().process_frame
	if token: 
		_fetch_user()
		sync_timer.start()
		_check_remote_updates()

func _exit_tree():
	if dock: remove_control_from_docks(dock); dock.free()
	for r in http_pool: r.queue_free()

# ==============================================================================
# SMART SYNC (ОДНА КНОПКА)
# ==============================================================================
func smart_sync(local_files: Array, message: String):
	_log("Синхронизация...", Color.YELLOW)
	
	# 1. Проверяем сервер
	var remote_head = await _get_sha(branch)
	if not remote_head: _finish(false, "Нет связи с GitHub."); return

	# 2. Если SHA отличаются, сначала делаем PULL
	if last_known_sha != "" and remote_head != last_known_sha:
		_log("Обнаружены изменения на сервере. Скачивание...", Color.AQUA)
		var pull_ok = await _do_pull(remote_head)
		if not pull_ok: return # Ошибка пулла, останавливаемся
	
	# 3. Теперь делаем PUSH (с учетом удалений)
	await _do_push(remote_head, local_files, message)

# ==============================================================================
# ЛОГИКА PULL
# ==============================================================================
func _do_pull(head_sha) -> bool:
	var tree_sha = await _get_commit_tree(head_sha)
	var remote_files = await _get_tree_recursive(tree_sha)
	
	var to_download = []
	for f in remote_files:
		if f["type"] == "blob" and not _is_ignored("res://" + f["path"]):
			to_download.append(f)
	
	if to_download.is_empty(): 
		last_known_sha = head_sha
		return true # Всё чисто
	
	var results = await _start_queue(to_download, false)
	
	for item in results:
		var path = "res://" + item["path"]
		var content = item["data"]
		
		# Бэкап при конфликте
		if FileAccess.file_exists(path):
			var existing = FileAccess.open(path, FileAccess.READ)
			if existing.get_length() != content.size():
				DirAccess.rename_absolute(path, path + BACKUP_EXT)
		
		var base_dir = path.get_base_dir()
		if not DirAccess.dir_exists_absolute(base_dir): DirAccess.make_dir_recursive_absolute(base_dir)
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f: f.store_buffer(content)
	
	last_known_sha = head_sha
	EditorInterface.get_resource_filesystem().scan()
	return true

# ==============================================================================
# ЛОГИКА PUSH (С УДАЛЕНИЕМ)
# ==============================================================================
func _do_push(base_sha, local_files_paths: Array, message: String):
	_log("Подготовка к отправке...", Color.YELLOW)
	
	# 1. Загружаем новые/измененные файлы
	var blobs_input = []
	for p in local_files_paths: blobs_input.append({"path": p})
	
	var uploaded_blobs = []
	if not blobs_input.is_empty():
		uploaded_blobs = await _start_queue(blobs_input, true)
		if uploaded_blobs.size() != blobs_input.size():
			_finish(false, "Ошибка загрузки файлов."); return
	
	# 2. Получаем старое дерево
	var old_tree_sha = await _get_commit_tree(base_sha)
	var old_remote_files = await _get_tree_recursive(old_tree_sha)
	
	# 3. Строим НОВОЕ дерево
	var final_tree = []
	var processed_paths = {}
	
	# А) Добавляем то, что мы только что загрузили
	for b in uploaded_blobs:
		final_tree.append(b)
		processed_paths[b["path"]] = true
	
	# Б) Обрабатываем старые файлы (ОСТАВИТЬ или УДАЛИТЬ?)
	var deleted_count = 0
	for old in old_remote_files:
		var p = old["path"]
		if old["type"] != "blob": continue # Игнорируем папки, гит сам разберется
		if processed_paths.has(p): continue # Уже обновлен
		
		# ГЛАВНАЯ МАГИЯ:
		# Если файл есть локально -> Оставляем (sha старый)
		# Если файла НЕТ локально -> Пропускаем (это и есть удаление из дерева)
		
		if FileAccess.file_exists("res://" + p):
			final_tree.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })
		else:
			# Файла нет локально. Проверяем, не игнорируемый ли он?
			if _is_ignored("res://" + p):
				# Если он игнорируемый, но был на сервере - лучше оставить, чтобы не ломать конфиги
				final_tree.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })
			else:
				# Файл отслеживаемый, но удален локально -> УДАЛЯЕМ С СЕРВЕРА
				deleted_count += 1
				# Просто НЕ добавляем в final_tree
	
	if uploaded_blobs.is_empty() and deleted_count == 0:
		_finish(true, "Нет изменений.")
		return
		
	_log("Коммит (Upd: %d, Del: %d)..." % [uploaded_blobs.size(), deleted_count], Color.AQUA)
	
	var new_tree_sha = await _create_tree(final_tree)
	if not new_tree_sha: _finish(false, "Ошибка создания дерева."); return
	
	var commit_sha = await _create_commit(message, new_tree_sha, base_sha)
	if not commit_sha: _finish(false, "Ошибка коммита."); return
	
	var ok = await _update_ref(branch, commit_sha)
	if ok:
		last_known_sha = commit_sha
		_finish(true, "Синхронизация успешна!")
	else:
		_finish(false, "Конфликт версий.")

# ==============================================================================
# ФОНОВЫЙ МОНИТОРИНГ
# ==============================================================================
func _check_remote_updates():
	if not token or not repo_name: return
	# Тихий запрос (не спамим в лог)
	var sha = await _get_sha(branch)
	if sha and last_known_sha and sha != last_known_sha:
		emit_signal("remote_update_detected") # Сигнал интерфейсу

# ==============================================================================
# ОЧЕРЕДЬ (EVENT DRIVEN)
# ==============================================================================
var _q_items = []; var _q_res = []; var _q_act = 0; var _q_tot = 0; var _q_up = false; signal _q_done
func _start_queue(items, up) -> Array:
	_q_items = items.duplicate(); _q_res = []; _q_tot = items.size(); _q_up = up; _q_act = 0
	emit_signal("progress", "Старт", 0, _q_tot)
	for i in range(4): http_busy[i] = false
	_pump(); await self._q_done; return _q_res
func _pump():
	if _q_items.is_empty() and _q_act == 0: emit_signal("_q_done"); return
	for i in range(4):
		if _q_items.is_empty(): break
		if not http_busy[i]:
			_q_act += 1; http_busy[i] = true; _run_w(i, _q_items.pop_front())
func _run_w(i, item):
	var req = http_pool[i]; req.cancel_request()
	var url = "https://api.github.com/repos/%s/%s/git/blobs" % [owner_name, repo_name]
	var err = OK
	if _q_up:
		var f = FileAccess.open(item["path"], FileAccess.READ)
		if f:
			var b64 = Marshalls.raw_to_base64(f.get_buffer(f.get_length()))
			err = req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify({"content": b64, "encoding": "base64"}))
		else: err = FAILED
	else:
		url += "/" + item["sha"]; err = req.request(url, _headers(), HTTPClient.METHOD_GET)
	var _end = func(r):
		if r: _q_res.append(r)
		http_busy[i] = false; _q_act -= 1; call_deferred("emit_signal", "progress", "...", _q_tot - _q_items.size() - _q_act, _q_tot); call_deferred("_pump")
	if err != OK: _end.call(null); return
	var res = await req.request_completed
	if res[1] in [200, 201]:
		var j = JSON.parse_string(res[3].get_string_from_utf8())
		if j:
			if _q_up: _end.call({ "path": item["path"].replace("res://", ""), "mode": "100644", "type": "blob", "sha": j["sha"] })
			else: _end.call({ "path": item["path"], "data": Marshalls.base64_to_raw(j["content"]) })
		else: _end.call(null)
	else: _end.call(null)

# ==============================================================================
# API
# ==============================================================================
func _headers(): return ["Authorization: token " + token.strip_edges(), "Accept: application/vnd.github.v3+json", "User-Agent: GodotGitPro"]
func _api(m, ep, d=null):
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	h.request("https://api.github.com/repos/%s/%s%s" % [owner_name.strip_edges(), repo_name.strip_edges(), ep], _headers(), m, JSON.stringify(d) if d else "")
	var r = await h.request_completed; h.queue_free()
	return { "c": r[1], "d": JSON.parse_string(r[3].get_string_from_utf8()) }
func _get_sha(b): var r = await _api(0, "/git/refs/heads/" + b); return r.d.get("object", {}).get("sha", "")
func _get_commit_tree(s): var r = await _api(0, "/git/commits/" + s); return r.d.get("tree", {}).get("sha", "")
func _get_tree_recursive(s): var r = await _api(0, "/git/trees/%s?recursive=1" % s); return r.d.get("tree", [])
func _create_tree(t): var r = await _api(HTTPClient.METHOD_POST, "/git/trees", {"tree": t}); return r.d.get("sha", "")
func _create_commit(m, t, p): var r = await _api(HTTPClient.METHOD_POST, "/git/commits", {"message": m, "tree": t, "parents": [p]}); return r.d.get("sha", "")
func _update_ref(b, s): var r = await _api(HTTPClient.METHOD_PATCH, "/git/refs/heads/" + b, {"sha": s}); return r.c == 200
func _fetch_user():
	var r = await _api(0, "/user") # Исправлен путь, используем общий _api
	if r.c == 200:
		user_data.login = r.d.get("login", "")
		user_data.name = r.d.get("name", user_data.login)
		call_deferred("emit_signal", "state_changed")
		_load_avatar(r.d.get("avatar_url"))

func _load_avatar(url):
	if !url: return
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	h.request(url); var r = await h.request_completed; h.queue_free()
	if r[1] == 200:
		var i = Image.new()
		if i.load_jpg_from_buffer(r[3]) != OK: if i.load_png_from_buffer(r[3]) != OK: i.load_webp_from_buffer(r[3])
		user_data.avatar = ImageTexture.create_from_image(i)
		call_deferred("emit_signal", "state_changed")

# --- UTILS ---
func _log(m, c): emit_signal("log_msg", m, c); print("[GitPro] ", m)
func _finish(s, m): _log(m, Color.GREEN if s else Color.RED); emit_signal("operation_done", s)
func _is_ignored(path: String) -> bool: return path.contains("/.godot/") or path.contains("/.git/") or path.ends_with(".uid") or path.ends_with(".bak")
func _load_cfg():
	var c = ConfigFile.new(); if c.load(USER_CFG)==OK: token=c.get_value("auth","token","").strip_edges()
	if c.load(PROJ_CFG)==OK: owner_name=c.get_value("git","owner","").strip_edges(); repo_name=c.get_value("git","repo","").strip_edges()
func save_token(t): token=t.strip_edges(); var c=ConfigFile.new(); c.set_value("auth","token",token); c.save(USER_CFG); if token: _fetch_user()
func save_proj(o,r): owner_name=o.strip_edges(); repo_name=r.strip_edges(); var c=ConfigFile.new(); c.set_value("git","owner",owner_name); c.set_value("git","repo",repo_name); c.save(PROJ_CFG)
func get_magic_link(): return "https://github.com/settings/tokens/new?scopes=repo,user,workflow,gist&description=GodotGitPro_Client"
