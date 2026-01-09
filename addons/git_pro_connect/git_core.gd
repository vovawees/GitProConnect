@tool
extends EditorPlugin
class_name GitProCore

# --- КОНФИГУРАЦИЯ ---
const USER_SETTINGS = "user://git_user_auth.cfg" 
var PROJ_SETTINGS = get_script().resource_path.get_base_dir().path_join("git_project_config.cfg")
const MAX_THREADS = 4
const UPDATE_URL = "https://api.github.com/repos/vovawees/GitProConnect/zipball/main"

# --- ДАННЫЕ ---
var github_token = ""
var repo_owner = ""
var repo_name = ""
var current_branch = "main"
var user_login = ""
var user_avatar_texture: Texture2D = null

# --- СИСТЕМА ---
var utils: GitUtils
var http_pool: Array[HTTPRequest] = []
var http_busy: Array[bool] = [] # Занят ли конкретный воркер
var dock_instance: Control = null

# --- СОСТОЯНИЕ ЗАГРУЗКИ (Для событийной модели) ---
var _upload_queue: Array = []
var _upload_results: Array = []
var _upload_total: int = 0
var _upload_processed: int = 0

# --- СИГНАЛЫ ---
signal log_message(msg: String, color: Color)
signal operation_progress(current: int, total: int, step_name: String)
signal user_profile_loaded(login: String, texture: Texture2D)
signal operation_finished(success: bool)
signal update_status(msg: String)
signal _internal_upload_finished # Внутренний сигнал для выхода из await

func _enter_tree():
	utils = GitUtils.new()
	utils.load_gitignore()
	
	http_busy.resize(MAX_THREADS)
	for i in range(MAX_THREADS):
		http_busy[i] = false
		var req = HTTPRequest.new()
		req.timeout = 25.0
		req.set_tls_options(TLSOptions.client_unsafe())
		add_child(req)
		http_pool.append(req)
	
	_load_settings()
	if github_token != "":
		_fetch_user_profile()
	
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
# ЛОГИКА СИНХРОНИЗАЦИИ
# ==============================================================================

func push_batch(local_files_to_push: Array, message: String):
	if local_files_to_push.is_empty(): 
		_safe_finish(true)
		return
	
	print("--- START BATCH ---")
	_safe_log("1/5 Проверка...", Color.YELLOW)
	
	var head_sha = await _get_ref_sha(current_branch)
	if head_sha == "":
		_safe_log("Ветка '%s' не найдена." % current_branch, Color.ORANGE)
		_safe_finish(false)
		return

	_safe_log("2/5 Анализ сервера...", Color.YELLOW)
	var remote_tree_sha = await _get_commit_tree_sha(head_sha)
	var remote_files = []
	if remote_tree_sha != "":
		remote_files = await _get_full_recursive_tree(remote_tree_sha)
	
	_safe_log("3/5 Загрузка файлов...", Color.YELLOW)
	
	# ЗАПУСК НОВОЙ СИСТЕМЫ ЗАГРУЗКИ
	var uploaded_blobs = await _upload_blobs_event_driven(local_files_to_push)
	
	print("Upload finished. Files: ", uploaded_blobs.size())
	
	if uploaded_blobs.is_empty() and not local_files_to_push.is_empty():
		_safe_log("Ошибка: Файлы не загрузились.", Color.RED)
		_safe_finish(false)
		return
		
	_safe_log("4/5 Синхронизация...", Color.AQUA)
	var final_tree = []
	var processed_paths = []
	
	# 1. Новые файлы
	for blob in uploaded_blobs:
		final_tree.append(blob)
		processed_paths.append(blob["path"])
	
	# 2. Старые файлы (если они есть локально)
	for r_file in remote_files:
		var r_path = r_file["path"]
		if r_path in processed_paths: continue
		if r_file["type"] != "blob": continue
		
		if FileAccess.file_exists("res://" + r_path):
			final_tree.append({ "path": r_path, "mode": r_file["mode"], "type": "blob", "sha": r_file["sha"] })
		else:
			print("Deleting remote: ", r_path)
	
	var new_tree_sha = await _create_tree_full(final_tree)
	if new_tree_sha == "":
		_safe_log("Ошибка создания Tree.", Color.RED)
		_safe_finish(false)
		return
		
	_safe_log("5/5 Коммит...", Color.AQUA)
	var new_commit_sha = await _create_commit(message, new_tree_sha, head_sha)
	if new_commit_sha == "":
		_safe_log("Ошибка создания Commit.", Color.RED)
		_safe_finish(false)
		return
		
	var success = await _update_ref(current_branch, new_commit_sha)
	if success:
		_safe_log("УСПЕХ!", Color.GREEN)
		_safe_finish(true)
	else:
		_safe_log("Ошибка Ref.", Color.RED)
		_safe_finish(false)

# ==============================================================================
# СОБЫТИЙНАЯ ЗАГРУЗКА (БЕЗ WHILE LOOP)
# ==============================================================================

func _upload_blobs_event_driven(paths: Array) -> Array:
	# Инициализация
	_upload_queue = paths.duplicate()
	_upload_results = []
	_upload_total = paths.size()
	_upload_processed = 0
	
	for i in range(MAX_THREADS): http_busy[i] = false
	
	call_deferred("emit_signal", "operation_progress", 0, _upload_total, "Старт...")
	
	# Запускаем первичную накачку
	_pump_queue()
	
	# Ждем сигнала окончания. Это не грузит CPU и не зависит от fps.
	await self._internal_upload_finished
	
	return _upload_results

func _pump_queue():
	# Если всё обработано - выходим
	if _upload_processed >= _upload_total:
		# Используем call_deferred, чтобы сигнал прошел чисто
		if _upload_processed == _upload_total: # Эмиттим только 1 раз
			_upload_processed += 1 # Чтобы не зайти сюда дважды
			emit_signal("_internal_upload_finished")
		return

	# Ищем свободные воркеры и раздаем задачи
	for i in range(MAX_THREADS):
		if _upload_queue.is_empty(): break
		
		if not http_busy[i]:
			var req = http_pool[i]
			req.cancel_request() # Сброс
			
			var path = _upload_queue.pop_front()
			http_busy[i] = true # Занимаем слот
			
			# Запускаем обработку
			_process_single_blob(req, i, path)

func _process_single_blob(http_node: HTTPRequest, slot_idx: int, path: String):
	# Вспомогательная функция завершения одного файла
	var _finish_file = func(blob_data):
		if blob_data:
			_upload_results.append(blob_data)
			print("Uploaded (%s/%s): %s" % [_upload_processed + 1, _upload_total, path.get_file()])
		else:
			print("Fail: ", path.get_file())
		
		_upload_processed += 1
		call_deferred("emit_signal", "operation_progress", _upload_processed, _upload_total, path.get_file())
		
		# Освобождаем слот
		http_busy[slot_idx] = false
		
		# Пробуем взять следующий файл
		call_deferred("_pump_queue")
	
	# Чтение файла
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		_finish_file.call(null)
		return
		
	var content = file.get_buffer(file.get_length())
	var b64 = Marshalls.raw_to_base64(content).replace("\n", "")
	var payload = { "content": b64, "encoding": "base64" }
	var url = "https://api.github.com/repos/%s/%s/git/blobs" % [repo_owner, repo_name]
	
	var err = http_node.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		_finish_file.call(null)
		return
	
	# Ждем ответ
	var res = await http_node.request_completed
	# res = [result, code, headers, body]
	
	if res[1] == 201:
		var json = JSON.parse_string(res[3].get_string_from_utf8())
		if json and "sha" in json:
			var blob = {
				"path": path.replace("res://", ""),
				"mode": "100644",
				"type": "blob",
				"sha": json["sha"]
			}
			_finish_file.call(blob)
		else:
			_finish_file.call(null)
	else:
		print("Error code: ", res[1], " for ", path)
		_finish_file.call(null)

# ==============================================================================
# API HELPERS (БЕЗ ИЗМЕНЕНИЙ)
# ==============================================================================

func _safe_log(msg, col):
	call_deferred("emit_signal", "log_message", msg, col)
	print("GitPro: ", msg)

func _safe_finish(success):
	call_deferred("emit_signal", "operation_finished", success)

func _headers():
	return ["Authorization: token " + github_token, "Accept: application/vnd.github.v3+json", "User-Agent: Godot-GitPro"]

func _request(method_str, endpoint, payload = null):
	var http = HTTPRequest.new()
	http.set_tls_options(TLSOptions.client_unsafe())
	add_child(http)
	var m = HTTPClient.METHOD_GET
	match method_str:
		"POST": m = HTTPClient.METHOD_POST
		"PATCH": m = HTTPClient.METHOD_PATCH
	http.request("https://api.github.com" + endpoint, _headers(), m, JSON.stringify(payload) if payload else "")
	var res = await http.request_completed
	http.queue_free()
	return {"code": res[1], "json": JSON.parse_string(res[3].get_string_from_utf8())}

# ... (API methods) ...
func _get_ref_sha(branch):
	var res = await _request("GET", "/repos/%s/%s/git/refs/heads/%s" % [repo_owner, repo_name, branch])
	if res.code == 200: return res.json["object"]["sha"]
	return ""
func _get_commit_tree_sha(commit_sha):
	var res = await _request("GET", "/repos/%s/%s/git/commits/%s" % [repo_owner, repo_name, commit_sha])
	if res.code == 200: return res.json["tree"]["sha"]
	return ""
func _get_full_recursive_tree(tree_sha):
	var res = await _request("GET", "/repos/%s/%s/git/trees/%s?recursive=1" % [repo_owner, repo_name, tree_sha])
	if res.code == 200 and "tree" in res.json: return res.json["tree"]
	return []
func _create_tree_full(tree_items):
	var payload = { "tree": tree_items }
	var res = await _request("POST", "/repos/%s/%s/git/trees" % [repo_owner, repo_name], payload)
	if res.code == 201: return res.json["sha"]
	return ""
func _create_commit(msg, tree_sha, parent_sha):
	var payload = { "message": msg, "tree": tree_sha, "parents": [parent_sha] }
	var res = await _request("POST", "/repos/%s/%s/git/commits" % [repo_owner, repo_name], payload)
	if res.code == 201: return res.json["sha"]
	return ""
func _update_ref(branch, commit_sha):
	var payload = { "sha": commit_sha, "force": false }
	var res = await _request("PATCH", "/repos/%s/%s/git/refs/heads/%s" % [repo_owner, repo_name, branch], payload)
	return res.code == 200

# SETTINGS
func save_user_auth(token):
	github_token = token
	var cfg = ConfigFile.new()
	cfg.set_value("auth", "token", token)
	cfg.save(USER_SETTINGS)
	if token != "": _fetch_user_profile()
func save_project_config(owner_name, repo):
	repo_owner = owner_name
	repo_name = repo
	var cfg = ConfigFile.new()
	cfg.set_value("git", "owner", repo_owner)
	cfg.set_value("git", "repo", repo_name)
	cfg.save(PROJ_SETTINGS)
func _load_settings():
	var u = ConfigFile.new()
	if u.load(USER_SETTINGS) == OK: github_token = u.get_value("auth", "token", "")
	var p = ConfigFile.new()
	if p.load(PROJ_SETTINGS) == OK:
		repo_owner = p.get_value("git", "owner", "")
		repo_name = p.get_value("git", "repo", "")
func _fetch_user_profile():
	var res = await _request("GET", "/user")
	if res.code == 200:
		user_login = res.json.get("login", "User")
		if res.json.get("avatar_url"): _download_avatar(res.json.get("avatar_url"))
func _download_avatar(url):
	var http = HTTPRequest.new()
	http.set_tls_options(TLSOptions.client_unsafe())
	add_child(http)
	http.request(url)
	var res = await http.request_completed
	http.queue_free()
	if res[1] == 200:
		var img = Image.new()
		if img.load_jpg_from_buffer(res[3]) != OK: img.load_png_from_buffer(res[3])
		user_avatar_texture = ImageTexture.create_from_image(img)
		emit_signal("user_profile_loaded", user_login, user_avatar_texture)
func check_and_update():
	call_deferred("emit_signal", "update_status", "Скачивание...")
	var http = HTTPRequest.new()
	http.set_tls_options(TLSOptions.client_unsafe())
	add_child(http)
	http.request(UPDATE_URL)
	var res = await http.request_completed
	http.queue_free()
	if res[1] == 200:
		var zip = ZIPReader.new()
		if zip.open_from_buffer(res[3]) == OK:
			var files = zip.get_files()
			var base = get_script().resource_path.get_base_dir()
			for f in files:
				if f.ends_with("/"): continue
				var dest = base.path_join(f.get_file())
				var file_w = FileAccess.open(dest, FileAccess.WRITE)
				if file_w: file_w.store_buffer(zip.read_file(f))
			call_deferred("emit_signal", "update_status", "Готово! Перезагрузите.")
			EditorInterface.get_resource_filesystem().scan()
	else:
		call_deferred("emit_signal", "update_status", "Ошибка обновления.")
