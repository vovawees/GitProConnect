@tool
extends EditorPlugin
class_name GitProCore

# --- КОНФИГ ---
const CURRENT_VERSION = "6.0"
const USER_CFG = "user://git_pro_auth.cfg" # Личный токен (не шарится)
# Этот файл лежит в проекте, он ОБЩИЙ для всех. Его надо закоммитить!
const PROJ_CFG = "res://addons/git_pro_connect/git_project_config.cfg" 
const BACKUP_EXT = ".bak"
const SYNC_INTERVAL = 60.0 

# --- ССЫЛКИ ОБНОВЛЕНИЯ ---
const UPDATE_CHECK_URL = "https://raw.githubusercontent.com/vovawees/GitProConnect/main/addons/git_pro_connect/plugin.cfg"
const UPDATE_ZIP_URL = "https://api.github.com/repos/vovawees/GitProConnect/zipball/main"

# --- ДАННЫЕ ---
var token = ""
var owner_name = ""
var repo_name = ""
var branch = "main"
var last_known_sha = ""
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
signal remote_update_detected
signal plugin_update_available(new_version: String) # Сигнал о новой версии плагина

func _enter_tree():
	# Создаем воркеры
	for i in range(4):
		var r = HTTPRequest.new(); r.timeout = 60.0; r.set_tls_options(TLSOptions.client_unsafe())
		add_child(r); http_pool.append(r); http_busy.append(false)
	
	sync_timer = Timer.new(); sync_timer.wait_time = SYNC_INTERVAL; sync_timer.timeout.connect(_check_remote_updates)
	add_child(sync_timer)
	
	_ensure_project_config_exists() # Создаем общий конфиг, если нет
	_load_cfg()
	
	var ui_res = load("res://addons/git_pro_connect/git_ui.gd")
	if ui_res:
		dock = ui_res.new(self)
		dock.name = "GitPro"
		add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)
		
	await get_tree().process_frame
	
	# Проверка обновления плагина при старте
	_check_plugin_version()
	
	if token: 
		_fetch_user()
		sync_timer.start()

func _exit_tree():
	if dock: remove_control_from_docks(dock); dock.free()
	for r in http_pool: r.queue_free()

# ==============================================================================
# PLUGIN AUTO-UPDATE SYSTEM
# ==============================================================================
func _check_plugin_version():
	var h = HTTPRequest.new(); add_child(h); h.set_tls_options(TLSOptions.client_unsafe())
	h.request(UPDATE_CHECK_URL)
	var r = await h.request_completed; h.queue_free()
	
	if r[1] == 200:
		var text = r[3].get_string_from_utf8()
		var regex = RegEx.new()
		regex.compile("version=\"([0-9.]+)\"")
		var result = regex.search(text)
		if result:
			var new_ver = result.get_string(1)
			if _compare_versions(new_ver, CURRENT_VERSION):
				print("[GitPro] Доступно обновление: v", new_ver)
				emit_signal("plugin_update_available", new_ver)

func install_plugin_update():
	_log("Скачивание обновления...", Color.YELLOW)
	var h = HTTPRequest.new(); add_child(h); h.set_tls_options(TLSOptions.client_unsafe())
	h.request(UPDATE_ZIP_URL)
	var r = await h.request_completed; h.queue_free()
	
	if r[1] == 200:
		var zip = ZIPReader.new()
		var err = zip.open_from_buffer(r[3])
		if err == OK:
			var files = zip.get_files()
			var base_path = "res://addons/git_pro_connect/"
			
			for file in files:
				# GitHub ZIP имеет корневую папку (напр. GitProConnect-main/), пропускаем её
				if not file.contains("addons/git_pro_connect/"): continue
				if file.ends_with("/"): continue # Пропускаем папки
				
				# Вырезаем путь, чтобы получить только имя файла внутри плагина
				var local_name = file.get_file() 
				# ВНИМАНИЕ: Это упрощение. Предполагается плоская структура или сохранение структуры.
				# Для надежности просто берем файлы и кладем в корень плагина, если структура совпадает.
				
				# Читаем и пишем
				var content = zip.read_file(file)
				var f = FileAccess.open(base_path.path_join(local_name), FileAccess.WRITE)
				if f: f.store_buffer(content)
			
			zip.close()
			_log("Обновлено! Перезагрузите проект.", Color.GREEN)
			EditorInterface.get_resource_filesystem().scan()
			await get_tree().create_timer(1.0).timeout
			EditorInterface.restart_editor(true)
		else:
			_finish(false, "Ошибка ZIP архива")
	else:
		_finish(false, "Ошибка скачивания обновления")

func _compare_versions(v1: String, v2: String) -> bool:
	var p1 = v1.split("."); var p2 = v2.split(".")
	for i in range(min(p1.size(), p2.size())):
		if p1[i].to_int() > p2[i].to_int(): return true
		if p1[i].to_int() < p2[i].to_int(): return false
	return false

# ==============================================================================
# SHARED CONFIG LOGIC
# ==============================================================================
func _ensure_project_config_exists():
	if not FileAccess.file_exists(PROJ_CFG):
		var c = ConfigFile.new()
		# Дефолтные значения (Ваш репозиторий)
		c.set_value("git", "owner", "vovawees")
		c.set_value("git", "repo", "GitProConnect")
		c.save(PROJ_CFG)

func save_proj(o, r): 
	owner_name = o.strip_edges()
	repo_name = r.strip_edges()
	var c = ConfigFile.new()
	c.set_value("git", "owner", owner_name)
	c.set_value("git", "repo", repo_name)
	c.save(PROJ_CFG) # Сохраняем в общий файл
	
	# Сразу говорим движку, что файл изменился, чтобы он попал в список на коммит
	EditorInterface.get_resource_filesystem().scan() 

# ==============================================================================
# SMART SYNC
# ==============================================================================
func smart_sync(local_files: Array, message: String):
	_log("Синхронизация...", Color.YELLOW)
	var remote_head = await _get_sha(branch)
	if not remote_head: _finish(false, "Нет связи с GitHub."); return

	if last_known_sha != "" and remote_head != last_known_sha:
		_log("Скачивание изменений...", Color.AQUA)
		var pull_ok = await _do_pull(remote_head)
		if not pull_ok: return 
	
	await _do_push_optimized(remote_head, local_files, message)

func _do_pull(head_sha) -> bool:
	var tree_sha = await _get_commit_tree(head_sha)
	var remote_files = await _get_tree_recursive(tree_sha)
	var to_download = []
	for f in remote_files:
		if f["type"] == "blob" and not _is_ignored("res://" + f["path"]): to_download.append(f)
	
	if to_download.is_empty(): last_known_sha = head_sha; return true
	var results = await _start_queue(to_download, false)
	
	for item in results:
		var path = "res://" + item["path"]
		var content = item["data"]
		if FileAccess.file_exists(path):
			var existing = FileAccess.open(path, FileAccess.READ)
			if existing.get_length() != content.size(): DirAccess.rename_absolute(path, path + BACKUP_EXT)
		var base_dir = path.get_base_dir()
		if not DirAccess.dir_exists_absolute(base_dir): DirAccess.make_dir_recursive_absolute(base_dir)
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f: f.store_buffer(content)
	
	last_known_sha = head_sha
	EditorInterface.get_resource_filesystem().scan()
	return true

func _do_push_optimized(base_sha, local_files_paths: Array, message: String):
	_log("Анализ файлов...", Color.YELLOW)
	var old_tree_sha = await _get_commit_tree(base_sha)
	var old_remote_files = await _get_tree_recursive(old_tree_sha)
	
	var remote_sha_map = {}; var remote_path_map = {}
	for r in old_remote_files:
		if r["type"] == "blob": remote_sha_map[r["sha"]] = true; remote_path_map[r["path"]] = r["sha"]
	
	var files_to_upload = []; var final_tree_items = []; var processed_local_paths = {}; var auto_msg_files = []
	var count = 0
	emit_signal("progress", "Хеширование", 0, local_files_paths.size())
	
	for path in local_files_paths:
		count += 1; if count % 10 == 0: emit_signal("progress", "Хеширование", count, local_files_paths.size()); await get_tree().process_frame
		var local_sha = _calculate_git_sha(path)
		var rel_path = path.replace("res://", "")
		processed_local_paths[rel_path] = true
		
		if remote_sha_map.has(local_sha):
			final_tree_items.append({ "path": rel_path, "mode": "100644", "type": "blob", "sha": local_sha })
			if remote_path_map.get(rel_path) != local_sha: auto_msg_files.append(rel_path.get_file())
		else:
			files_to_upload.append({"path": path}); auto_msg_files.append(rel_path.get_file())
	
	if not files_to_upload.is_empty():
		_log("Загрузка %d новых файлов..." % files_to_upload.size(), Color.AQUA)
		var uploaded = await _start_queue(files_to_upload, true)
		if uploaded.size() != files_to_upload.size(): _finish(false, "Ошибка загрузки."); return
		for u in uploaded: final_tree_items.append(u)
	else: _log("Дедупликация: ОК.", Color.GREEN)

	var deleted_count = 0
	for old in old_remote_files:
		var p = old["path"]; if old["type"] != "blob": continue
		if processed_local_paths.has(p): continue
		if FileAccess.file_exists("res://" + p): final_tree_items.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })
		else: if not _is_ignored("res://" + p): deleted_count += 1
		else: final_tree_items.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })

	if auto_msg_files.is_empty() and deleted_count == 0: _finish(true, "Нет изменений."); return
	if message.strip_edges() == "":
		var f_names = ", ".join(auto_msg_files.slice(0, 3)); if auto_msg_files.size() > 3: f_names += " (+%d)" % (auto_msg_files.size() - 3)
		message = "Upd: " + f_names; if deleted_count > 0: message += ", Del: %d" % deleted_count

	_log("Коммит: " + message, Color.AQUA)
	var new_tree_sha = await _create_tree(final_tree_items)
	if not new_tree_sha: _finish(false, "Ошибка Tree."); return
	var commit_sha = await _create_commit(message, new_tree_sha, base_sha)
	if not commit_sha: _finish(false, "Ошибка Commit."); return
	var ok = await _update_ref(branch, commit_sha)
	if ok: last_known_sha = commit_sha; _finish(true, "Успех!")
	else: _finish(false, "Конфликт.")

func _calculate_git_sha(path: String) -> String:
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return ""
	var content = f.get_buffer(f.get_length())
	var header_str = "blob " + str(content.size())
	var header_bytes = header_str.to_utf8_buffer()
	header_bytes.append(0)
	var ctx = HashingContext.new(); ctx.start(HashingContext.HASH_SHA1); ctx.update(header_bytes); ctx.update(content)
	return ctx.finish().hex_encode()

# ==============================================================================
# NETWORK
# ==============================================================================
func _headers(): return ["Authorization: token " + token.strip_edges(), "Accept: application/vnd.github.v3+json", "Accept-Encoding: gzip, deflate", "User-Agent: GodotGitPro"]
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
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	h.request("https://api.github.com/user", _headers(), 0)
	var r = await h.request_completed; h.queue_free()
	if r[1] == 200:
		var d = JSON.parse_string(r[3].get_string_from_utf8())
		if d:
			user_data.login = d.get("login", "")
			user_data.name = d.get("name", user_data.login)
			if user_data.name == null: user_data.name = user_data.login
			_load_avatar(d.get("avatar_url"))
			call_deferred("emit_signal", "state_changed")

func _load_avatar(url):
	if !url: return
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	h.request(url); var r = await h.request_completed; h.queue_free()
	if r[1] == 200:
		var i = Image.new()
		if i.load_jpg_from_buffer(r[3]) != OK: if i.load_png_from_buffer(r[3]) != OK: i.load_webp_from_buffer(r[3])
		user_data.avatar = ImageTexture.create_from_image(i)
		call_deferred("emit_signal", "state_changed")

func _check_remote_updates():
	if not token or not repo_name: return
	var sha = await _get_sha(branch)
	if sha and last_known_sha and sha != last_known_sha: emit_signal("remote_update_detected")

# --- QUEUE ---
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
		if not http_busy[i]: _q_act += 1; http_busy[i] = true; _run_w(i, _q_items.pop_front())
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

# --- UTILS ---
func _log(m, c): emit_signal("log_msg", m, c); print("[GitPro] ", m)
func _finish(s, m): _log(m, Color.GREEN if s else Color.RED); emit_signal("operation_done", s)
func _is_ignored(path: String) -> bool: return path.contains("/.godot/") or path.contains("/.git/") or path.ends_with(".uid") or path.ends_with(".bak")
func _load_cfg():
	var c = ConfigFile.new(); 
	if c.load(USER_CFG)==OK: token=c.get_value("auth","token","").strip_edges()
	# Грузим общий конфиг
	if c.load(PROJ_CFG)==OK: 
		owner_name=c.get_value("git","owner","vovawees").strip_edges()
		repo_name=c.get_value("git","repo","GitProConnect").strip_edges()
		
func save_token(t): token=t.strip_edges(); var c=ConfigFile.new(); c.set_value("auth","token",token); c.save(USER_CFG); if token: _fetch_user()
func get_magic_link(): return "https://github.com/settings/tokens/new?scopes=repo,user,workflow,gist&description=GodotGitPro_Client"
