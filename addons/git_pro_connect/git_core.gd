@tool
extends EditorPlugin
class_name GitProCore

# --- КОНФИГУРАЦИЯ ---
const USER_SETTINGS = "user://git_user_auth.cfg" 
var PROJ_SETTINGS = get_script().resource_path.get_base_dir().path_join("git_project_config.cfg")
const MAX_THREADS = 4 # Оптимально для стабильности
const MAX_FILE_SIZE = 45 * 1024 * 1024 # 45 MB Limit
const UPDATE_URL = "https://api.github.com/repos/vovawees/GitProConnect/zipball/main"

# --- ДАННЫЕ ---
var github_token = ""
var repo_owner = ""
var repo_name = ""
var current_branch = "main"
var branches_list = []
var last_known_commit_sha = ""

var user_login = ""
var user_avatar_texture: Texture2D = null

# --- СИСТЕМА ---
var utils: GitUtils
var http_pool: Array[HTTPRequest] = []
var http_busy: Array[bool] = []
var dock_instance: Control = null

# --- СОСТОЯНИЕ ОЧЕРЕДИ (Event Driven) ---
var _queue: Array = []
var _results: Array = []
var _total: int = 0
var _processed: int = 0
var _mode = "upload" # "upload" | "download"

# --- СИГНАЛЫ ---
signal log_message(msg: String, color: Color)
signal operation_progress(current: int, total: int, step_name: String)
signal user_profile_loaded(login: String, texture: Texture2D)
signal operation_finished(success: bool)
signal update_status(msg: String)
signal branches_loaded(branches: Array, current: String)
signal history_loaded(commits: Array)
signal _internal_finished # Внутренний сигнал завершения очереди

func _enter_tree():
	utils = GitUtils.new()
	utils.load_gitignore()
	
	http_busy.resize(MAX_THREADS)
	for i in range(MAX_THREADS):
		http_busy[i] = false
		var req = HTTPRequest.new()
		req.timeout = 30.0
		req.set_tls_options(TLSOptions.client_unsafe())
		add_child(req)
		http_pool.append(req)
	
	_load_settings()
	if github_token != "":
		_fetch_user_profile()
		fetch_branches()
	
	var ui_script = load("res://addons/git_pro_connect/git_ui.gd")
	if ui_script:
		dock_instance = ui_script.new(self)
		dock_instance.name = "GitProConnect"
		add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, dock_instance)

func _exit_tree():
	if dock_instance:
		remove_control_from_docks(dock_instance)
		dock_instance.free()
		dock_instance = null
	for req in http_pool: req.queue_free()

# ==============================================================================
# SMART PULL (СКАЧИВАНИЕ)
# ==============================================================================

func pull_smart():
	_safe_log("Начало PULL...", Color.YELLOW)
	
	# 1. SHA ветки
	var head_sha = await _get_ref_sha(current_branch)
	if head_sha == "":
		_safe_log("Ветка '%s' не найдена или репо пуст." % current_branch, Color.RED)
		_safe_finish(false)
		return
		
	# 2. Скачиваем дерево
	_safe_log("Анализ изменений...", Color.YELLOW)
	var tree_sha = await _get_commit_tree_sha(head_sha)
	var remote_files = await _get_full_recursive_tree(tree_sha)
	
	var files_to_download = []
	
	# 3. Сравнение
	for r_file in remote_files:
		if r_file["type"] != "blob": continue
		var path = "res://" + r_file["path"]
		
		if utils.is_ignored(path): continue
		
		# Качаем, если файла нет или просто для надежности (Overwrite strategy)
		files_to_download.append(r_file)

	if files_to_download.is_empty():
		_safe_log("Все файлы актуальны.", Color.GREEN)
		_safe_finish(true)
		return

	_safe_log("Скачивание %s файлов..." % files_to_download.size(), Color.YELLOW)
	
	# 4. Запуск скачивания
	_mode = "download"
	await _process_queue_event_driven(files_to_download)
	
	# 5. Обновление
	_safe_log("Обновление редактора...", Color.AQUA)
	EditorInterface.get_resource_filesystem().scan()
	last_known_commit_sha = head_sha
	_safe_log("PULL завершен!", Color.GREEN)
	_safe_finish(true)

# ==============================================================================
# SMART PUSH (ОТПРАВКА)
# ==============================================================================

func push_batch(local_files_to_push: Array, message: String):
	if local_files_to_push.is_empty(): 
		_safe_finish(true)
		return
	
	# Проверка размера
	var valid_files = []
	for p in local_files_to_push:
		var f = FileAccess.open(p, FileAccess.READ)
		if f:
			if f.get_length() > MAX_FILE_SIZE:
				_safe_log("ПРОПУСК (Big File > 45MB): " + p.get_file(), Color.ORANGE)
			else:
				valid_files.append(p)
	
	if valid_files.is_empty():
		_safe_log("Нет валидных файлов.", Color.RED)
		_safe_finish(false)
		return

	_safe_log("1/5 Проверка...", Color.YELLOW)
	var head_sha = await _get_ref_sha(current_branch)
	if head_sha == "":
		_safe_log("Ветка '%s' не найдена." % current_branch, Color.ORANGE)
		_safe_finish(false)
		return

	_safe_log("2/5 Анализ...", Color.YELLOW)
	var remote_tree_sha = await _get_commit_tree_sha(head_sha)
	var remote_files = []
	if remote_tree_sha != "":
		remote_files = await _get_full_recursive_tree(remote_tree_sha)
	
	_safe_log("3/5 Загрузка...", Color.YELLOW)
	_mode = "upload"
	var uploaded_blobs = await _process_queue_event_driven(valid_files)
	
	if uploaded_blobs.is_empty():
		_safe_log("Ошибка: Файлы не загрузились.", Color.RED)
		_safe_finish(false)
		return
		
	_safe_log("4/5 Сборка...", Color.AQUA)
	var final_tree = []
	var processed_paths = []
	
	# Добавляем новые
	for blob in uploaded_blobs:
		final_tree.append(blob)
		processed_paths.append(blob["path"])
	
	# Сохраняем старые (если они есть локально)
	for r_file in remote_files:
		var r_path = r_file["path"]
		if r_path in processed_paths: continue
		if r_file["type"] != "blob": continue
		
		if FileAccess.file_exists("res://" + r_path):
			final_tree.append({ "path": r_path, "mode": r_file["mode"], "type": "blob", "sha": r_file["sha"] })
		else:
			print("Deleting remote (removed locally): ", r_path)
	
	var new_tree_sha = await _create_tree_full(final_tree)
	if new_tree_sha == "":
		_safe_log("Ошибка Tree.", Color.RED)
		_safe_finish(false)
		return
		
	_safe_log("5/5 Коммит...", Color.AQUA)
	var new_commit_sha = await _create_commit(message, new_tree_sha, head_sha)
	if new_commit_sha == "":
		_safe_log("Ошибка Commit.", Color.RED)
		_safe_finish(false)
		return
		
	var success = await _update_ref(current_branch, new_commit_sha)
	if success:
		last_known_commit_sha = new_commit_sha
		_safe_log("УСПЕХ!", Color.GREEN)
		_safe_finish(true)
	else:
		_safe_log("КОНФЛИКТ! Сделайте PULL.", Color.RED)
		_safe_finish(false)

# ==============================================================================
# УНИВЕРСАЛЬНАЯ ОЧЕРЕДЬ (EVENT DRIVEN)
# ==============================================================================

func _process_queue_event_driven(items: Array) -> Array:
	_queue = items.duplicate()
	_results = []
	_total = items.size()
	_processed = 0
	
	for i in range(MAX_THREADS): http_busy[i] = false
	
	call_deferred("emit_signal", "operation_progress", 0, _total, "Старт...")
	
	# Запуск рекурсивной накачки
	_pump_queue()
	
	# Ждем сигнала, не блокируя поток
	await self._internal_finished
	
	return _results

func _pump_queue():
	if _processed >= _total:
		if _processed == _total:
			_processed += 1 # Блокируем повторный вход
			emit_signal("_internal_finished")
		return

	for i in range(MAX_THREADS):
		if _queue.is_empty(): break
		
		if not http_busy[i]:
			var req = http_pool[i]
			req.cancel_request() # Сброс старого запроса
			
			var item = _queue.pop_front()
			http_busy[i] = true
			
			if _mode == "upload":
				_worker_upload(req, i, item)
			else:
				_worker_download(req, i, item)

func _worker_upload(http_node, slot, path):
	var _done = func(data):
		if data: 
			_results.append(data)
			print("Up: ", path.get_file())
		else: 
			print("Fail Up: ", path.get_file())
		
		_processed += 1
		call_deferred("emit_signal", "operation_progress", _processed, _total, path.get_file())
		http_busy[slot] = false
		call_deferred("_pump_queue")

	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		_done.call(null)
		return
		
	var b64 = Marshalls.raw_to_base64(file.get_buffer(file.get_length())).replace("\n", "")
	var url = "https://api.github.com/repos/%s/%s/git/blobs" % [repo_owner, repo_name]
	var err = http_node.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify({ "content": b64, "encoding": "base64" }))
	
	if err != OK: _done.call(null); return
	
	var res = await http_node.request_completed
	if res[1] == 201:
		var json = JSON.parse_string(res[3].get_string_from_utf8())
		if json and "sha" in json:
			_done.call({ "path": path.replace("res://", ""), "mode": "100644", "type": "blob", "sha": json["sha"] })
		else: _done.call(null)
	else: _done.call(null)

func _worker_download(http_node, slot, remote_file_obj):
	var path = "res://" + remote_file_obj["path"]
	var sha = remote_file_obj["sha"]
	
	var _done = func(success):
		if success: print("Down: ", path.get_file())
		else: print("Fail Down: ", path.get_file())
		
		_processed += 1
		call_deferred("emit_signal", "operation_progress", _processed, _total, path.get_file())
		http_busy[slot] = false
		call_deferred("_pump_queue")
	
	var url = "https://api.github.com/repos/%s/%s/git/blobs/%s" % [repo_owner, repo_name, sha]
	var err = http_node.request(url, _headers(), HTTPClient.METHOD_GET)
	
	if err != OK: _done.call(false); return
	
	var res = await http_node.request_completed
	if res[1] == 200:
		var json = JSON.parse_string(res[3].get_string_from_utf8())
		if json and "content" in json:
			var content = Marshalls.base64_to_raw(json["content"])
			var dir = path.get_base_dir()
			if not DirAccess.dir_exists_absolute(dir):
				DirAccess.make_dir_recursive_absolute(dir)
			
			var f = FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_buffer(content)
				f.close()
				_done.call(true)
			else: _done.call(false)
		else: _done.call(false)
	else: _done.call(false)

# ==============================================================================
# BRANCHES & HISTORY & UPDATE
# ==============================================================================

func fetch_branches():
	var res = await _request("GET", "/repos/%s/%s/branches" % [repo_owner, repo_name])
	if res.code == 200 and res.json is Array:
		branches_list.clear()
		for b in res.json:
			branches_list.append(b["name"])
		emit_signal("branches_loaded", branches_list, current_branch)

func create_new_branch(new_name):
	_safe_log("Создание ветки %s..." % new_name, Color.YELLOW)
	var head_sha = await _get_ref_sha(current_branch)
	if head_sha == "": return
	
	var payload = { "ref": "refs/heads/" + new_name, "sha": head_sha }
	var res = await _request("POST", "/repos/%s/%s/git/refs" % [repo_owner, repo_name], payload)
	
	if res.code == 201:
		_safe_log("Ветка создана!", Color.GREEN)
		current_branch = new_name
		fetch_branches()
	else:
		_safe_log("Ошибка создания ветки.", Color.RED)

func fetch_history():
	var res = await _request("GET", "/repos/%s/%s/commits?sha=%s&per_page=15" % [repo_owner, repo_name, current_branch])
	if res.code == 200 and res.json is Array:
		var clean = []
		for c in res.json:
			var msg = c["commit"]["message"]
			var date = c["commit"]["author"]["date"]
			var author = c["commit"]["author"]["name"]
			clean.append({"msg": msg, "date": date, "author": author})
		emit_signal("history_loaded", clean)

func check_for_updates_silent():
	# Используем первый воркер, если он свободен
	if http_pool[0].get_http_client_status() != HTTPClient.STATUS_DISCONNECTED: return false
	
	var req = http_pool[0]
	var url = "https://api.github.com/repos/%s/%s/git/refs/heads/%s" % [repo_owner, repo_name, current_branch]
	req.request(url, _headers(), HTTPClient.METHOD_GET)
	var res = await req.request_completed
	
	if res[1] == 200:
		var json = JSON.parse_string(res[3].get_string_from_utf8())
		var server_sha = json["object"]["sha"]
		
		if last_known_commit_sha != "" and server_sha != last_known_commit_sha:
			call_deferred("emit_signal", "log_message", "ЕСТЬ ОБНОВЛЕНИЯ НА СЕРВЕРЕ!", Color.MAGENTA)
			return true
		
		if last_known_commit_sha == "":
			last_known_commit_sha = server_sha
			
	return false

# ==============================================================================
# API HELPER (STANDARD)
# ==============================================================================

func _safe_log(msg, col): call_deferred("emit_signal", "log_message", msg, col); print("GitPro: ", msg)
func _safe_finish(s): call_deferred("emit_signal", "operation_finished", s)

func _headers():
	return ["Authorization: token " + github_token, "Accept: application/vnd.github.v3+json", "User-Agent: Godot-GitPro"]

func _request(m_str, ep, pl = null):
	var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h)
	var m = HTTPClient.METHOD_POST if m_str == "POST" else (HTTPClient.METHOD_PATCH if m_str == "PATCH" else HTTPClient.METHOD_GET)
	h.request("https://api.github.com" + ep, _headers(), m, JSON.stringify(pl) if pl else "")
	var res = await h.request_completed; h.queue_free()
	return {"code": res[1], "json": JSON.parse_string(res[3].get_string_from_utf8())}

func _get_ref_sha(b):
	var r = await _request("GET", "/repos/%s/%s/git/refs/heads/%s" % [repo_owner, repo_name, b])
	return r.json["object"]["sha"] if r.code == 200 else ""
func _get_commit_tree_sha(s):
	var r = await _request("GET", "/repos/%s/%s/git/commits/%s" % [repo_owner, repo_name, s])
	return r.json["tree"]["sha"] if r.code == 200 else ""
func _get_full_recursive_tree(s):
	var r = await _request("GET", "/repos/%s/%s/git/trees/%s?recursive=1" % [repo_owner, repo_name, s])
	return r.json["tree"] if r.code == 200 and "tree" in r.json else []
func _create_tree_full(ti):
	var r = await _request("POST", "/repos/%s/%s/git/trees" % [repo_owner, repo_name], { "tree": ti })
	return r.json["sha"] if r.code == 201 else ""
func _create_commit(m, t, p):
	var r = await _request("POST", "/repos/%s/%s/git/commits" % [repo_owner, repo_name], { "message": m, "tree": t, "parents": [p] })
	return r.json["sha"] if r.code == 201 else ""
func _update_ref(b, s):
	var r = await _request("PATCH", "/repos/%s/%s/git/refs/heads/%s" % [repo_owner, repo_name, b], { "sha": s, "force": false })
	return r.code == 200

# SETTINGS
func save_user_auth(t): github_token = t; var c = ConfigFile.new(); c.set_value("auth", "token", t); c.save(USER_SETTINGS); if t: _fetch_user_profile()
func save_project_config(o, r): repo_owner = o; repo_name = r; var c = ConfigFile.new(); c.set_value("git", "owner", o); c.set_value("git", "repo", r); c.save(PROJ_SETTINGS)
func _load_settings(): 
	var u = ConfigFile.new(); if u.load(USER_SETTINGS) == OK: github_token = u.get_value("auth", "token", "")
	var p = ConfigFile.new(); if p.load(PROJ_SETTINGS) == OK: repo_owner = p.get_value("git", "owner", ""); repo_name = p.get_value("git", "repo", "")
func _fetch_user_profile(): var r = await _request("GET", "/user"); if r.code == 200: user_login = r.json.get("login", "User"); if r.json.get("avatar_url"): _download_avatar(r.json.get("avatar_url"))
func _download_avatar(u): var h = HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h); h.request(u); var r = await h.request_completed; h.queue_free(); if r[1]==200: var i=Image.new(); if i.load_jpg_from_buffer(r[3])!=OK: i.load_png_from_buffer(r[3]); user_avatar_texture=ImageTexture.create_from_image(i); emit_signal("user_profile_loaded", user_login, user_avatar_texture)
func check_and_update(): call_deferred("emit_signal", "update_status", "Скачивание..."); var h=HTTPRequest.new(); h.set_tls_options(TLSOptions.client_unsafe()); add_child(h); h.request(UPDATE_URL); var r=await h.request_completed; h.queue_free(); if r[1]==200: var z=ZIPReader.new(); if z.open_from_buffer(r[3])==OK: var b=get_script().resource_path.get_base_dir(); for f in z.get_files(): if !f.ends_with("/"): var fw=FileAccess.open(b.path_join(f.get_file()),FileAccess.WRITE); if fw: fw.store_buffer(z.read_file(f)); call_deferred("emit_signal", "update_status", "Готово! Рестарт."); EditorInterface.get_resource_filesystem().scan()
