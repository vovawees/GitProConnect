@tool
extends EditorPlugin
class_name GitProCore

const VERSION = "13.1 FIX"
const USER_CFG = "user://git_pro_auth.cfg"
const PROJ_CFG = "res://addons/git_pro_connect/git_project_config.cfg"
const SYNC_INTERVAL = 60.0
const MAX_FILE_SIZE = 99 * 1024 * 1024 # 99 MB Лимит

# --- ДАННЫЕ ---
var token = ""
var owner_name = ""
var repo_name = ""
var branch = "main"
var last_known_sha = ""
var user_data = { "name": "Гость", "login": "", "avatar": null }
var branches_list = []
var gitignore_rules = []
var auto_refresh_issues = true
var rate_limit_remaining = "???"

# --- СИСТЕМА ---
var http_pool: Array[HTTPRequest] = []
var http_busy: Array[bool] = []
var sync_timer: Timer
var dock: Control
var hash_thread: Thread

signal log_msg(m: String, c: Color)
signal progress(s: String, c: int, t: int)
signal state_changed
signal operation_done(ok: bool)
signal remote_update_detected
signal history_loaded(data: Array)
signal branches_loaded(list: Array, current: String)
signal blob_content_loaded(content: String, path: String)
signal issues_loaded(list: Array)
signal issue_comments_loaded(list: Array)
signal issue_updated
signal file_reverted(path: String)

func _enter_tree():
	hash_thread = Thread.new()
	for i in range(4): 
		var r = HTTPRequest.new()
		r.timeout = 60.0
		r.set_tls_options(TLSOptions.client_unsafe())
		add_child(r)
		http_pool.append(r)
		http_busy.append(false)
	
	sync_timer = Timer.new()
	sync_timer.wait_time = SYNC_INTERVAL
	sync_timer.timeout.connect(_on_timer_tick)
	add_child(sync_timer)
	
	_load_cfg()
	_load_gitignore()
	
	var ui_res = load("res://addons/git_pro_connect/git_ui.gd")
	if ui_res: 
		dock = ui_res.new(self)
		dock.name = "GitPro"
		add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)
	
	await get_tree().process_frame
	if token: 
		_fetch_user()
		sync_timer.start()
		fetch_branches()
		await get_tree().create_timer(1.0).timeout
		fetch_history()

func _exit_tree():
	if hash_thread and hash_thread.is_started():
		hash_thread.wait_to_finish()
	if dock: 
		remove_control_from_docks(dock)
		dock.free()
	for r in http_pool:
		r.queue_free()

# ==============================================================================
# SMART SYNC
# ==============================================================================
func smart_sync(local_files: Array, message: String):
	_log("Подготовка к синхронизации (%d файлов)..." % local_files.size(), Color.GOLD)
	
	if local_files.is_empty():
		_finish(false, "Ошибка: Файлы не выбраны! Поставьте галочки.")
		return

	# 1. Проверка размера
	for p in local_files:
		var f = FileAccess.open(p, FileAccess.READ)
		if f and f.get_length() > MAX_FILE_SIZE:
			_finish(false, "Критично: Файл >99MB (GitHub не примет): " + p.get_file())
			return

	# 2. SHA ветки
	var remote_head = await _get_sha(branch)
	if not remote_head: 
		_finish(false, "Нет связи с GitHub или репозиторий пуст.")
		return

	if last_known_sha == "":
		last_known_sha = remote_head

	# 3. Pull
	if remote_head != last_known_sha:
		_log("Сервер обновился. Скачиваю изменения (Pull)...", Color.DEEP_SKY_BLUE)
		var ok = await _do_pull(remote_head)
		if not ok: return
	
	# 4. Push
	_start_push_process(remote_head, local_files, message)

func _do_pull(head_sha) -> bool:
	var tree_sha = await _get_commit_tree(head_sha)
	var remote_files = await _get_tree_recursive(tree_sha)
	var to_down = []
	for f in remote_files:
		if f["type"] == "blob" and not _is_ignored("res://" + f["path"]): 
			to_down.append(f)
	
	if to_down.is_empty(): 
		last_known_sha = head_sha
		return true
		
	var res = await _start_queue(to_down, false)
	for item in res:
		_write_file_safe("res://" + item["path"], item["data"])
	
	last_known_sha = head_sha
	EditorInterface.get_resource_filesystem().scan()
	return true

func _start_push_process(base_sha, local_paths, msg):
	if hash_thread and hash_thread.is_started():
		hash_thread.wait_to_finish()
	
	if not hash_thread:
		hash_thread = Thread.new()
		
	emit_signal("progress", "Вычисление хешей...", 0, local_paths.size())
	hash_thread.start(_thread_hashing_task.bind([base_sha, local_paths, msg]))

func _thread_hashing_task(args):
	var base_sha = args[0]
	var local_paths = args[1]
	var msg = args[2]
	
	var calculated_hashes = {}
	var processed_count = 0
	
	for path in local_paths:
		var sha = _calculate_git_sha(path)
		calculated_hashes[path] = sha
		processed_count += 1
		call_deferred("emit_signal", "progress", "Хеширование...", processed_count, local_paths.size())
	
	call_deferred("_finalize_push", base_sha, local_paths, msg, calculated_hashes)

func _finalize_push(base_sha, local_paths, msg, local_hashes):
	if hash_thread and hash_thread.is_started():
		hash_thread.wait_to_finish()
		
	_log("Анализ изменений...", Color.GOLD)
	
	var old_tree_sha = await _get_commit_tree(base_sha)
	var old_files = await _get_tree_recursive(old_tree_sha)
	var remote_map = {}
	for r in old_files:
		if r["type"] == "blob":
			remote_map[r["sha"]] = true
	
	var to_upload = []
	var final_tree = []
	var processed_rel_paths = {}
	var auto_msg_files = []
	
	for path in local_paths:
		var sha = local_hashes[path]
		var rel = path.replace("res://", "")
		processed_rel_paths[rel] = true
		
		if remote_map.has(sha):
			final_tree.append({ "path": rel, "mode": "100644", "type": "blob", "sha": sha })
		else:
			to_upload.append({"path": path})
			auto_msg_files.append(rel.get_file())

	if not to_upload.is_empty():
		_log("Загрузка файлов (%d)..." % to_upload.size(), Color.DEEP_SKY_BLUE)
		var uploaded = await _start_queue(to_upload, true)
		if uploaded.size() != to_upload.size(): 
			_finish(false, "Ошибка сети при загрузке файлов.")
			return
		for u in uploaded:
			final_tree.append(u)
	
	var del_cnt = 0
	for old in old_files:
		var p = old["path"]
		if old["type"] != "blob" or processed_rel_paths.has(p):
			continue
		
		if FileAccess.file_exists("res://" + p):
			final_tree.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })
		elif not _is_ignored("res://" + p):
			del_cnt += 1
		else:
			final_tree.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })

	if to_upload.is_empty() and del_cnt == 0: 
		_finish(true, "Нет изменений для отправки.")
		return
	
	if msg.strip_edges() == "": 
		msg = "Обновление: " + ", ".join(auto_msg_files.slice(0, 2))
		if auto_msg_files.size() > 2: msg += "..."
		if del_cnt > 0: msg += ", Удалено: %d" % del_cnt

	_log("Фиксация коммита...", Color.DEEP_SKY_BLUE)
	var new_tree = await _create_tree(final_tree)
	if not new_tree:
		_finish(false, "Ошибка создания Tree")
		return
		
	var commit = await _create_commit(msg, new_tree, base_sha)
	if not commit:
		_finish(false, "Ошибка создания Commit")
		return
	
	if await _update_ref(branch, commit): 
		last_known_sha = commit
		_finish(true, "Успешно синхронизировано!")
		fetch_history()
	else: 
		_finish(false, "Конфликт версий. Повторите попытку.")

# ==============================================================================
# API & UTILS
# ==============================================================================
func _calculate_git_sha(path: String) -> String:
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return ""
	var content = f.get_buffer(f.get_length())
	var header = ("blob " + str(content.size())).to_utf8_buffer()
	header.append(0)
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(header)
	ctx.update(content)
	return ctx.finish().hex_encode()

func _headers():
	return ["Authorization: token " + token.strip_edges(), "Accept: application/vnd.github.v3+json", "User-Agent: GodotGitPro"]

func _api(m, ep, d=null, use_repo=true):
	var h = HTTPRequest.new()
	h.set_tls_options(TLSOptions.client_unsafe())
	add_child(h)
	var base = "https://api.github.com/repos/%s/%s"%[owner_name,repo_name] if use_repo else "https://api.github.com"
	h.request(base + ep, _headers(), m, JSON.stringify(d) if d else "")
	var r = await h.request_completed
	h.queue_free()
	
	if r[2].has("X-RateLimit-Remaining"):
		rate_limit_remaining = r[2]["X-RateLimit-Remaining"]
	
	var json = null
	if r[1] != 204 and r[3].size() > 0:
		var test_json = JSON.parse_string(r[3].get_string_from_utf8())
		if test_json != null:
			json = test_json
			
	return { "c": r[1], "d": json }

func revert_file(path: String):
	_log("Откат файла...", Color.GOLD)
	var tree_sha = await _get_commit_tree(last_known_sha if last_known_sha else (await _get_sha(branch)))
	var remote_files = await _get_tree_recursive(tree_sha)
	var rel = path.replace("res://", "")
	var file_sha = ""
	for f in remote_files:
		if f["path"] == rel:
			file_sha = f["sha"]
			break
	
	if file_sha == "":
		_finish(false, "Файл отсутствует на сервере.")
		return
	
	var r = await _api(0, "/git/blobs/" + file_sha)
	if r.c == 200:
		var content = Marshalls.base64_to_raw(r.d["content"])
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(content)
			f.close()
			EditorInterface.get_resource_filesystem().scan()
			emit_signal("file_reverted", path)
			_finish(true, "Файл восстановлен до версии сервера.")

# Shortened API wrappers (Expanded for safety)
func _get_sha(b):
	var r = await _api(0, "/git/refs/heads/" + b)
	return r.d.get("object", {}).get("sha", "")

func _get_commit_tree(s):
	var r = await _api(0, "/git/commits/" + s)
	return r.d.get("tree", {}).get("sha", "")

func _get_tree_recursive(s):
	var r = await _api(0, "/git/trees/%s?recursive=1" % s)
	return r.d.get("tree", [])

func _create_tree(t):
	var r = await _api(HTTPClient.METHOD_POST, "/git/trees", {"tree": t})
	return r.d.get("sha", "")

func _create_commit(m, t, p):
	var r = await _api(HTTPClient.METHOD_POST, "/git/commits", {"message": m, "tree": t, "parents": [p]})
	return r.d.get("sha", "")

func _update_ref(b, s):
	var r = await _api(HTTPClient.METHOD_PATCH, "/git/refs/heads/" + b, {"sha": s})
	return r.c == 200

func fetch_branches():
	var r = await _api(0, "/git/refs/heads")
	if r.c == 200:
		branches_list.clear()
		for item in r.d: 
			var b = item["ref"].replace("refs/heads/", "")
			branches_list.append(b)
			if b == branch:
				last_known_sha = item["object"]["sha"]
		emit_signal("branches_loaded", branches_list, branch)

func create_branch(n):
	var s = await _get_sha(branch)
	if !s: return
	var r = await _api(HTTPClient.METHOD_POST, "/git/refs", {"ref":"refs/heads/"+n, "sha":s})
	if r.c == 201:
		branch = n
		fetch_branches()
		_finish(true, "Ветка создана!")

func delete_branch(n):
	if n == branch:
		_finish(false, "Нельзя удалить активную ветку!")
		return
	var r = await _api(HTTPClient.METHOD_DELETE, "/git/refs/heads/"+n)
	if r.c == 204:
		_finish(true, "Ветка удалена!")
		fetch_branches()

func fetch_history():
	if branch == "": return
	var r = await _api(0, "/commits?sha="+branch+"&per_page=20")
	if r.c == 200:
		var c = []
		for i in r.d:
			c.append({
				"msg": i["commit"]["message"],
				"date": i["commit"]["author"]["date"].left(10),
				"author": i["commit"]["author"]["name"],
				"sha": i["sha"]
			})
		emit_signal("history_loaded", c)

func fetch_blob_content(sha, path):
	var r = await _api(0, "/git/blobs/" + sha)
	if r.c == 200:
		emit_signal("blob_content_loaded", Marshalls.base64_to_raw(r.d["content"]).get_string_from_utf8(), path)

# --- ISSUES ---
func fetch_issues():
	var r = await _api(0, "/issues?state=all&per_page=20&sort=updated")
	if r.c == 200:
		emit_signal("issues_loaded", r.d)

func create_issue_api(t, b):
	var r = await _api(HTTPClient.METHOD_POST, "/issues", {"title":t, "body":b})
	if r.c == 201:
		_finish(true, "Задача создана")
		fetch_issues()

func fetch_issue_comments(n):
	var r = await _api(0, "/issues/%s/comments"%n)
	if r.c == 200:
		emit_signal("issue_comments_loaded", r.d)

func post_issue_comment(n, b):
	if b.strip_edges() == "": return
	var r = await _api(HTTPClient.METHOD_POST, "/issues/%s/comments"%n, {"body":b})
	if r.c == 201:
		fetch_issue_comments(n)

func change_issue_state(n, cl):
	var s = "closed" if cl else "open"
	var r = await _api(HTTPClient.METHOD_PATCH, "/issues/%s"%n, {"state":s})
	if r.c == 200:
		fetch_issues()

# --- CONFIG ---
func _fetch_user():
	var r = await _api(0, "/user", null, false)
	if r.c == 200:
		user_data.login = r.d["login"]
		user_data.name = r.d.get("name", user_data.login)
		_load_avatar(r.d.get("avatar_url"))

func _load_avatar(u):
	if !u: return
	var h = HTTPRequest.new()
	add_child(h)
	h.request(u)
	var r = await h.request_completed
	h.queue_free()
	if r[1] == 200:
		var i = Image.new()
		if i.load_jpg_from_buffer(r[3]) != OK and i.load_png_from_buffer(r[3]) != OK:
			i.load_webp_from_buffer(r[3])
		user_data.avatar = ImageTexture.create_from_image(i)
		emit_signal("state_changed")

func _on_timer_tick():
	if token and repo_name:
		_check_remote()
	if auto_refresh_issues:
		fetch_issues()

func _check_remote():
	var s = await _get_sha(branch)
	if s and last_known_sha and s != last_known_sha:
		emit_signal("remote_update_detected")

func _write_file_safe(path, content):
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f.get_length() != content.size():
			DirAccess.rename_absolute(path, path + ".bak")
	var d = path.get_base_dir()
	if !DirAccess.dir_exists_absolute(d):
		DirAccess.make_dir_recursive_absolute(d)
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_buffer(content)

func _load_cfg():
	var c = ConfigFile.new()
	if c.load(USER_CFG) == OK:
		token = c.get_value("auth", "token", "").strip_edges()
	if c.load(PROJ_CFG) == OK:
		owner_name = c.get_value("git", "owner", "").strip_edges()
		repo_name = c.get_value("git", "repo", "").strip_edges()

func save_token(t):
	token = t.strip_edges()
	var c = ConfigFile.new()
	c.set_value("auth", "token", token)
	c.save(USER_CFG)
	if token: _fetch_user()

func save_proj(o, r):
	owner_name = o.strip_edges()
	repo_name = r.strip_edges()
	var c = ConfigFile.new()
	c.set_value("git", "owner", owner_name)
	c.set_value("git", "repo", repo_name)
	c.save(PROJ_CFG)

func get_magic_link():
	return "https://github.com/settings/tokens/new?scopes=repo,user,gist&description=GodotGitPro_Client"

func _load_gitignore():
	gitignore_rules.clear()
	gitignore_rules = [".godot/", ".git/", ".import/", "*.uid", "*.bak"]
	if FileAccess.file_exists("res://.gitignore"):
		var f = FileAccess.open("res://.gitignore", FileAccess.READ)
		while not f.eof_reached():
			var l = f.get_line().strip_edges()
			if l != "" and not l.begins_with("#"):
				gitignore_rules.append(l)

func _is_ignored(path):
	var rel = path.replace("res://", "")
	for r in gitignore_rules:
		if r.begins_with("*"):
			if rel.ends_with(r.substr(1)): return true
		elif r.ends_with("/"):
			if rel.begins_with(r) or rel.contains("/" + r): return true
		else:
			if rel == r: return true
			if rel.match(r): return true
	return false

func _log(m, c):
	emit_signal("log_msg", m, c)
	print("[GitPro] ", m)

func _finish(s, m):
	_log(m, Color.SPRING_GREEN if s else Color.TOMATO)
	emit_signal("operation_done", s)

# --- QUEUE ---
var _q_items = []
var _q_res = []
var _q_act = 0
var _q_tot = 0
var _q_up = false
signal _q_done

func _start_queue(i, u): 
	_q_items = i.duplicate()
	_q_res = []
	_q_tot = i.size()
	_q_up = u
	_q_act = 0
	emit_signal("progress", "Старт", 0, _q_tot)
	
	for x in 4: 
		http_busy[x] = false
	
	_pump()
	await self._q_done
	return _q_res

func _pump(): 
	if _q_items.is_empty() and _q_act == 0: 
		emit_signal("_q_done")
		return
	
	for x in 4: 
		if !_q_items.is_empty() and !http_busy[x]: 
			_q_act += 1
			http_busy[x] = true
			_run_w(x, _q_items.pop_front())

func _run_w(i, item):
	var req = http_pool[i]
	req.cancel_request()
	var url = "https://api.github.com/repos/%s/%s/git/blobs" % [owner_name, repo_name]
	
	if _q_up: 
		var f = FileAccess.open(item["path"], FileAccess.READ)
		if f: 
			var b64 = Marshalls.raw_to_base64(f.get_buffer(f.get_length()))
			req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify({"content": b64, "encoding": "base64"}))
		else: 
			_q_end(i, null)
			return
	else: 
		req.request(url + "/" + item["sha"], _headers(), HTTPClient.METHOD_GET)
	
	var r = await req.request_completed
	
	if r[1] in [200, 201]: 
		var j = JSON.parse_string(r[3].get_string_from_utf8())
		if _q_up: 
			_q_end(i, {"path": item["path"].replace("res://", ""), "mode": "100644", "type": "blob", "sha": j["sha"]})
		else: 
			_q_end(i, {"path": item["path"], "data": Marshalls.base64_to_raw(j["content"])})
	else: 
		_q_end(i, null)

func _q_end(i, res): 
	if res: _q_res.append(res)
	http_busy[i] = false
	_q_act -= 1
	call_deferred("emit_signal", "progress", "...", _q_tot - _q_items.size() - _q_act, _q_tot)
	call_deferred("_pump")
