@tool
extends EditorPlugin
class_name GitProCore

# --- НАСТРОЙКИ ---
const USER_CFG = "user://git_pro_auth.cfg"
const PROJ_CFG = "res://addons/git_pro_connect/git_config.cfg"
const BACKUP_EXT = ".bak"

# --- ДАННЫЕ ---
var token = ""
var owner_name = ""
var repo_name = ""
var branch = "main"
var user_data = { "name": "Гость", "login": "", "avatar": null }

# --- СИСТЕМА ---
var http_pool: Array[HTTPRequest] = []
var http_busy: Array[bool] = []
var dock: Control

# --- ОЧЕРЕДЬ ---
var _queue_items = []
var _queue_results = []
var _queue_active_workers = 0
var _queue_total = 0
var _queue_mode_upload = false
signal _internal_queue_finished

# --- СИГНАЛЫ ---
signal log_msg(text: String, color: Color)
signal progress(step: String, current: int, total: int)
signal state_changed
signal operation_done(success: bool)

func _enter_tree():
	for i in range(4):
		var r = HTTPRequest.new()
		r.timeout = 60.0
		r.set_tls_options(TLSOptions.client_unsafe())
		add_child(r)
		http_pool.append(r)
		http_busy.append(false)
	
	_load_cfg()
	
	var ui_res = load("res://addons/git_pro_connect/git_ui.gd")
	if ui_res:
		dock = ui_res.new(self)
		dock.name = "GitPro"
		add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)
		
	await get_tree().process_frame
	if token: _fetch_user()

func _exit_tree():
	if dock:
		remove_control_from_docks(dock)
		dock.free()
	for r in http_pool: r.queue_free()

# ==============================================================================
# ЛОГИКА
# ==============================================================================
func pull_safe():
	_log("Подключение...", Color.YELLOW)
	var head = await _get_sha(branch)
	if not head: _finish(false, "Ошибка: Ветка '%s' не найдена." % branch); return
	
	var tree_sha = await _get_commit_tree(head)
	var remote_files = await _get_tree_recursive(tree_sha)
	
	var to_download = []
	for f in remote_files:
		if f["type"] == "blob" and not _is_ignored("res://" + f["path"]):
			to_download.append(f)
	
	if to_download.is_empty(): _finish(true, "Все файлы актуальны."); return
	
	_log("Скачивание %d файлов..." % to_download.size(), Color.AQUA)
	var results = await _start_queue(to_download, false)
	
	_log("Сохранение...", Color.ORANGE)
	for item in results:
		var path = "res://" + item["path"]
		var content = item["data"]
		
		# Бэкап
		if FileAccess.file_exists(path):
			var existing = FileAccess.open(path, FileAccess.READ)
			if existing.get_length() != content.size():
				DirAccess.rename_absolute(path, path + BACKUP_EXT)
		
		var base_dir = path.get_base_dir()
		if not DirAccess.dir_exists_absolute(base_dir):
			DirAccess.make_dir_recursive_absolute(base_dir)
			
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f: f.store_buffer(content)
	
	EditorInterface.get_resource_filesystem().scan()
	_finish(true, "Успешно обновлено!")

func push_safe(files_paths: Array, message: String):
	_log("Проверка доступа...", Color.YELLOW)
	var head_sha = await _get_sha(branch)
	if not head_sha: _finish(false, "Ошибка доступа к репозиторию."); return
	
	_log("Загрузка %d файлов..." % files_paths.size(), Color.AQUA)
	var blobs_input = []
	for p in files_paths: blobs_input.append({"path": p})
	
	var uploaded_blobs = await _start_queue(blobs_input, true)
	if uploaded_blobs.is_empty(): _finish(false, "Не удалось загрузить файлы."); return
	
	_log("Сборка коммита...", Color.YELLOW)
	var old_tree_sha = await _get_commit_tree(head_sha)
	var old_tree_files = await _get_tree_recursive(old_tree_sha)
	
	var final_tree = []
	var new_paths = {}
	for b in uploaded_blobs:
		final_tree.append(b)
		new_paths[b["path"]] = true
	
	for old in old_tree_files:
		if old["type"] == "blob" and not new_paths.has(old["path"]):
			final_tree.append({ "path": old["path"], "mode": old["mode"], "type": "blob", "sha": old["sha"] })
			
	var new_tree_sha = await _create_tree(final_tree)
	if not new_tree_sha: _finish(false, "Ошибка создания дерева."); return
	
	var commit_sha = await _create_commit(message, new_tree_sha, head_sha)
	if not commit_sha: _finish(false, "Ошибка создания коммита."); return
	
	var ok = await _update_ref(branch, commit_sha)
	if ok: _finish(true, "УСПЕХ! Отправлено.")
	else: _finish(false, "КОНФЛИКТ! Кто-то уже запушил. Жми PULL.")

# ==============================================================================
# ОЧЕРЕДЬ
# ==============================================================================
func _start_queue(items: Array, is_upload: bool) -> Array:
	_queue_items = items.duplicate()
	_queue_results = []
	_queue_total = items.size()
	_queue_mode_upload = is_upload
	_queue_active_workers = 0
	
	emit_signal("progress", "Старт", 0, _queue_total)
	for i in range(http_pool.size()): http_busy[i] = false
	_pump_queue()
	await self._internal_queue_finished
	return _queue_results

func _pump_queue():
	if _queue_items.is_empty() and _queue_active_workers == 0:
		emit_signal("_internal_queue_finished")
		return

	for i in range(http_pool.size()):
		if _queue_items.is_empty(): break
		if not http_busy[i]:
			var item = _queue_items.pop_front()
			http_busy[i] = true
			_queue_active_workers += 1
			_run_worker(i, item)

func _run_worker(idx, item):
	var req = http_pool[idx]
	req.cancel_request()
	
	var url = "https://api.github.com/repos/%s/%s/git/blobs" % [owner_name, repo_name]
	var err = OK
	
	if _queue_mode_upload:
		var f = FileAccess.open(item["path"], FileAccess.READ)
		if f:
			var b64 = Marshalls.raw_to_base64(f.get_buffer(f.get_length()))
			err = req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify({"content": b64, "encoding": "base64"}))
		else: err = FAILED
	else:
		url += "/" + item["sha"]
		err = req.request(url, _headers(), HTTPClient.METHOD_GET)
	
	var _on_done = func(result):
		if result: _queue_results.append(result)
		else: print("![GitPro] Worker Fail: ", item)
		http_busy[idx] = false
		_queue_active_workers -= 1
		call_deferred("emit_signal", "progress", "В процессе...", _queue_total - _queue_items.size() - _queue_active_workers, _queue_total)
		call_deferred("_pump_queue")
	
	if err != OK: _on_done.call(null); return
	
	var res = await req.request_completed
	if res[1] in [200, 201]:
		var json = JSON.parse_string(res[3].get_string_from_utf8())
		if json:
			if _queue_mode_upload:
				_on_done.call({ "path": item["path"].replace("res://", ""), "mode": "100644", "type": "blob", "sha": json["sha"] })
			else:
				var raw = Marshalls.base64_to_raw(json["content"])
				_on_done.call({ "path": item["path"], "data": raw })
		else: _on_done.call(null)
	else: _on_done.call(null)

# ==============================================================================
# API (ИСПРАВЛЕННЫЕ МЕТОДЫ)
# ==============================================================================
func _headers(): 
	return ["Authorization: token " + token.strip_edges(), "Accept: application/vnd.github.v3+json", "User-Agent: GodotGitPro"]

func _api(method, ep, d=null):
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	var url = "https://api.github.com/repos/%s/%s%s" % [owner_name.strip_edges(), repo_name.strip_edges(), ep]
	
	h.request(url, _headers(), method, JSON.stringify(d) if d else "")
	var r = await h.request_completed; h.queue_free()
	
	var body_str = r[3].get_string_from_utf8()
	var json = JSON.parse_string(body_str)
	
	if json == null and method != HTTPClient.METHOD_HEAD:
		print("![GitPro] API Error (No Body): ", r[1], " on ", ep)
		return { "c": r[1], "d": {} }
		
	if r[1] not in [200, 201]: 
		print("![GitPro] API Error %d on %s: " % [r[1], ep], json.get("message", "") if json else "")
		
	return { "c": r[1], "d": json }

# ВАЖНО: ТЕПЕРЬ ИСПОЛЬЗУЕМ КОНСТАНТЫ GODOT, А НЕ ЧИСЛА
func _get_sha(b): var r = await _api(HTTPClient.METHOD_GET, "/git/refs/heads/" + b); return r.d.get("object", {}).get("sha", "")
func _get_commit_tree(s): var r = await _api(HTTPClient.METHOD_GET, "/git/commits/" + s); return r.d.get("tree", {}).get("sha", "")
func _get_tree_recursive(s): var r = await _api(HTTPClient.METHOD_GET, "/git/trees/%s?recursive=1" % s); return r.d.get("tree", [])

# ВОТ ЗДЕСЬ БЫЛА ОШИБКА (1 -> METHOD_POST)
func _create_tree(t): var r = await _api(HTTPClient.METHOD_POST, "/git/trees", {"tree": t}); return r.d.get("sha", "")
func _create_commit(m, t, p): var r = await _api(HTTPClient.METHOD_POST, "/git/commits", {"message": m, "tree": t, "parents": [p]}); return r.d.get("sha", "")

# ОБНОВЛЕНИЕ ТРЕБУЕТ PATCH (Обычно это 7 или 8, поэтому используем константу)
func _update_ref(b, s): var r = await _api(HTTPClient.METHOD_PATCH, "/git/refs/heads/" + b, {"sha": s}); return r.c == 200

func _fetch_user():
	print("[GitPro] Login check...")
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	h.request("https://api.github.com/user", _headers(), HTTPClient.METHOD_GET)
	var r = await h.request_completed; h.queue_free()
	
	if r[1] == 200:
		var d = JSON.parse_string(r[3].get_string_from_utf8())
		if d:
			user_data.login = d.get("login", "")
			user_data.name = d.get("name", user_data.login)
			if user_data.name == null: user_data.name = user_data.login
			print("[GitPro] Logged in as: ", user_data.login)
			call_deferred("emit_signal", "state_changed")
			_load_avatar(d.get("avatar_url"))
	else:
		print("[GitPro] Login Failed. Check token permissions.")

func _load_avatar(url):
	if not url: return
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	h.request(url); var r = await h.request_completed; h.queue_free()
	if r[1] == 200:
		var img = Image.new()
		if img.load_jpg_from_buffer(r[3]) != OK:
			if img.load_png_from_buffer(r[3]) != OK: img.load_webp_from_buffer(r[3])
		user_data.avatar = ImageTexture.create_from_image(img)
		call_deferred("emit_signal", "state_changed")

# --- UTILS ---
func _log(m, c): emit_signal("log_msg", m, c); print("[GitPro] ", m)
func _finish(s, m): _log(m, Color.GREEN if s else Color.RED); emit_signal("operation_done", s)
func _is_ignored(path: String) -> bool:
	if path.contains("/.godot/") or path.contains("/.git/") or path.ends_with(".uid"): return true
	return false

func _load_cfg():
	var c = ConfigFile.new()
	if c.load(USER_CFG) == OK: token = c.get_value("auth", "token", "").strip_edges()
	if c.load(PROJ_CFG) == OK: 
		owner_name = c.get_value("git", "owner", "").strip_edges()
		repo_name = c.get_value("git", "repo", "").strip_edges()

func save_token(t): 
	token = t.strip_edges()
	var c = ConfigFile.new(); c.set_value("auth", "token", token); c.save(USER_CFG)
	if token: _fetch_user()

func save_proj(o, r): 
	owner_name = o.strip_edges()
	repo_name = r.strip_edges()
	var c = ConfigFile.new(); c.set_value("git", "owner", owner_name); c.set_value("git", "repo", repo_name); c.save(PROJ_CFG)

func get_magic_link(): return "https://github.com/settings/tokens/new?scopes=repo,user,workflow,gist&description=GodotGitPro_Client"
