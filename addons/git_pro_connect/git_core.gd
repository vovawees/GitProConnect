@tool
extends EditorPlugin
class_name GitProCore

# --- КОНФИГ ---
const VERSION = "7.2"
const USER_CFG = "user://git_pro_auth.cfg"
const PROJ_CFG = "res://addons/git_pro_connect/git_project_config.cfg"
const CACHE_FILE = "user://git_pro_cache.dat"
const SYNC_INTERVAL = 60.0
const MAX_FILE_SIZE = 99 * 1024 * 1024 # 99 MB

# --- ДАННЫЕ ---
var token = ""
var owner_name = ""
var repo_name = ""
var branch = "main"
var last_known_sha = ""
var user_data = { "name": "Гость", "login": "", "avatar": null }
var branches_list = []
var file_cache = {} 
var gitignore_rules = []

# --- СИСТЕМА ---
var http_pool: Array[HTTPRequest] = []
var http_busy: Array[bool] = []
var sync_timer: Timer
var dock: Control

signal log_msg(m: String, c: Color)
signal progress(s: String, c: int, t: int)
signal state_changed
signal operation_done(ok: bool)
signal remote_update_detected
signal history_loaded(commits: Array)
signal branches_loaded(list: Array, current: String)
signal blob_content_loaded(content: String)

func _enter_tree():
	for i in range(4): 
		var r = HTTPRequest.new()
		r.timeout = 60.0
		r.set_tls_options(TLSOptions.client_unsafe())
		add_child(r)
		http_pool.append(r)
		http_busy.append(false)
	
	sync_timer = Timer.new()
	sync_timer.wait_time = SYNC_INTERVAL
	sync_timer.timeout.connect(_check_remote)
	add_child(sync_timer)
	
	_load_cache()
	_load_cfg()
	_load_gitignore()
	
	var ui_script = load("res://addons/git_pro_connect/git_ui.gd")
	if ui_script: 
		dock = ui_script.new(self)
		dock.name = "GitPro"
		add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)
	
	await get_tree().process_frame
	if token: 
		_fetch_user()
		sync_timer.start()
		fetch_branches()

func _exit_tree():
	if dock:
		remove_control_from_docks(dock)
		dock.free()
	for r in http_pool: r.queue_free()
	_save_cache()

# ==============================================================================
# LOGIC
# ==============================================================================
func smart_sync(local_files: Array, message: String):
	_log("Синхронизация...", Color.YELLOW)
	
	# Проверка на большие файлы
	for p in local_files:
		var f = FileAccess.open(p, FileAccess.READ)
		if f and f.get_length() > MAX_FILE_SIZE:
			_finish(false, "ОШИБКА: Файл > 100MB: " + p.get_file())
			return

	var remote_head = await _get_sha(branch)
	if not remote_head: 
		_finish(false, "Нет связи с GitHub.")
		return

	if last_known_sha != "" and remote_head != last_known_sha:
		_log("Скачивание изменений...", Color.AQUA)
		var ok = await _do_pull(remote_head)
		if not ok: return
	
	await _do_push(remote_head, local_files, message)

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
		var path = "res://" + item["path"]
		var content = item["data"]
		
		if FileAccess.file_exists(path):
			var existing = FileAccess.open(path, FileAccess.READ)
			if existing.get_length() != content.size(): 
				DirAccess.rename_absolute(path, path + ".bak")
		
		var dir = path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir): 
			DirAccess.make_dir_recursive_absolute(dir)
			
		var f = FileAccess.open(path, FileAccess.WRITE)
		if f: 
			f.store_buffer(content)
			f.close()
		_update_cache_entry(path, content)
	
	last_known_sha = head_sha
	EditorInterface.get_resource_filesystem().scan()
	return true

func _do_push(base_sha, local_paths: Array, msg: String):
	_log("Анализ...", Color.YELLOW)
	
	var old_tree_sha = await _get_commit_tree(base_sha)
	var old_files = await _get_tree_recursive(old_tree_sha)
	
	var remote_map = {}
	for r in old_files: 
		if r["type"] == "blob":
			remote_map[r["sha"]] = true
	
	var to_upload = []
	var final_tree = []
	var processed = {}
	var auto_msg = []
	var c = 0
	
	emit_signal("progress", "Анализ", 0, local_paths.size())
	
	for path in local_paths:
		c += 1
		if c % 20 == 0: 
			emit_signal("progress", "Анализ", c, local_paths.size())
			await get_tree().process_frame
			
		var sha = _get_sha_smart(path)
		var rel = path.replace("res://", "")
		processed[rel] = true
		
		if remote_map.has(sha):
			final_tree.append({ "path": rel, "mode": "100644", "type": "blob", "sha": sha })
		else:
			to_upload.append({"path": path})
			auto_msg.append(rel.get_file())
			
	if not to_upload.is_empty():
		_log("Загрузка %d файлов..." % to_upload.size(), Color.AQUA)
		var uploaded = await _start_queue(to_upload, true)
		if uploaded.size() != to_upload.size(): 
			_finish(false, "Ошибка загрузки.")
			return
		for u in uploaded: 
			final_tree.append(u)
	
	var del_cnt = 0
	for old in old_files:
		var p = old["path"]
		if old["type"] != "blob": continue
		if processed.has(p): continue
		
		if FileAccess.file_exists("res://" + p):
			final_tree.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })
		elif not _is_ignored("res://" + p):
			del_cnt += 1
		else:
			final_tree.append({ "path": p, "mode": old["mode"], "type": "blob", "sha": old["sha"] })

	if to_upload.is_empty() and del_cnt == 0: 
		_finish(true, "Нет изменений.")
		return
	
	if msg.strip_edges() == "": 
		msg = "Upd: " + ", ".join(auto_msg.slice(0, 2))
		if auto_msg.size() > 2: msg += "..."
		if del_cnt > 0: msg += ", Del: %d" % del_cnt

	_log("Коммит...", Color.AQUA)
	var new_tree = await _create_tree(final_tree)
	if not new_tree: 
		_finish(false, "Ошибка Tree.")
		return
	
	var commit = await _create_commit(msg, new_tree, base_sha)
	if !commit: 
		_finish(false, "Ошибка Commit.")
		return
	
	if await _update_ref(branch, commit): 
		last_known_sha = commit
		_finish(true, "Успех!")
	else: 
		_finish(false, "Конфликт.")

# ==============================================================================
# BRANCHES
# ==============================================================================
func fetch_branches():
	var r = await _api(0, "/git/refs/heads")
	if r.c == 200:
		branches_list.clear()
		for item in r.d:
			var b_name = item["ref"].replace("refs/heads/", "")
			branches_list.append(b_name)
		emit_signal("branches_loaded", branches_list, branch)

func create_branch(new_name: String):
	_log("Создание ветки " + new_name + "...", Color.YELLOW)
	var sha = await _get_sha(branch)
	if !sha: return
	var r = await _api(HTTPClient.METHOD_POST, "/git/refs", { "ref": "refs/heads/"+new_name, "sha": sha })
	if r.c == 201:
		branch = new_name
		fetch_branches()
		_finish(true, "Ветка создана!")
	else: 
		_finish(false, "Ошибка создания ветки.")

func fetch_history():
	var r = await _api(0, "/git/commits?sha=" + branch + "&per_page=15")
	if r.c == 200:
		var clean = []
		for c in r.d:
			clean.append({
				"msg": c["commit"]["message"],
				"date": c["commit"]["author"]["date"].replace("T", " ").replace("Z", ""),
				"author": c["commit"]["author"]["name"],
				"sha": c["sha"]
			})
		emit_signal("history_loaded", clean)

func fetch_blob_content(sha):
	var r = await _api(0, "/git/blobs/" + sha)
	if r.c == 200 and "content" in r.d:
		var txt = Marshalls.base64_to_raw(r.d["content"]).get_string_from_utf8()
		emit_signal("blob_content_loaded", txt)

# ==============================================================================
# CACHE
# ==============================================================================
func _load_cache():
	if FileAccess.file_exists(CACHE_FILE):
		var f = FileAccess.open(CACHE_FILE, FileAccess.READ)
		if f: file_cache = f.get_var()
	else: 
		file_cache = {}

func _save_cache():
	var f = FileAccess.open(CACHE_FILE, FileAccess.WRITE)
	if f: f.store_var(file_cache)

func _get_sha_smart(path: String) -> String:
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return ""
	var mtime = FileAccess.get_modified_time(path)
	
	if file_cache.has(path):
		var entry = file_cache[path]
		if entry["mtime"] == mtime: return entry["sha"]
	
	var content = f.get_buffer(f.get_length())
	var header = ("blob " + str(content.size())).to_utf8_buffer()
	header.append(0)
	
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(header)
	ctx.update(content)
	var sha = ctx.finish().hex_encode()
	
	file_cache[path] = { "mtime": mtime, "sha": sha }
	return sha

func _update_cache_entry(path, content_bytes):
	var mtime = FileAccess.get_modified_time(path)
	var header = ("blob " + str(content_bytes.size())).to_utf8_buffer()
	header.append(0)
	
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(header)
	ctx.update(content_bytes)
	file_cache[path] = { "mtime": mtime, "sha": ctx.finish().hex_encode() }

func _load_gitignore():
	gitignore_rules.clear()
	var hard = [".godot/", ".git/", ".import/", "*.uid", "*.bak"]
	for h in hard: gitignore_rules.append(h)
	
	if FileAccess.file_exists("res://.gitignore"):
		var f = FileAccess.open("res://.gitignore", FileAccess.READ)
		while not f.eof_reached():
			var line = f.get_line().strip_edges()
			if line != "" and not line.begins_with("#"):
				gitignore_rules.append(line)

func _is_ignored(path: String) -> bool:
	var rel = path.replace("res://", "")
	for rule in gitignore_rules:
		if rule.ends_with("/"):
			if rel.begins_with(rule) or rel.contains("/"+rule): return true
		elif rule.begins_with("*."):
			if rel.ends_with(rule.substr(1)): return true
		elif rel == rule: 
			return true
	return false

# ==============================================================================
# API
# ==============================================================================
func _headers(): 
	return ["Authorization: token " + token.strip_edges(), "Accept: application/vnd.github.v3+json", "Accept-Encoding: gzip", "User-Agent: GodotGitPro"]

func _api(m, ep, d=null):
	var h = HTTPRequest.new()
	h.set_tls_options(TLSOptions.client_unsafe())
	add_child(h)
	
	var url = "https://api.github.com/repos/%s/%s%s" % [owner_name.strip_edges(), repo_name.strip_edges(), ep]
	h.request(url, _headers(), m, JSON.stringify(d) if d else "")
	
	var r = await h.request_completed
	h.queue_free()
	
	var json = JSON.parse_string(r[3].get_string_from_utf8())
	return { "c": r[1], "d": json }

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

func _fetch_user():
	var h = HTTPRequest.new()
	h.set_tls_options(TLSOptions.client_unsafe())
	add_child(h)
	h.request("https://api.github.com/user", _headers(), 0)
	
	var r = await h.request_completed
	h.queue_free()
	
	if r[1] == 200:
		var d = JSON.parse_string(r[3].get_string_from_utf8())
		if d:
			user_data.login = d.get("login", "")
			user_data.name = d.get("name", user_data.login)
			if user_data.name == null: user_data.name = user_data.login
			_load_avatar(d.get("avatar_url"))
			call_deferred("emit_signal", "state_changed")

func _load_avatar(u):
	if not u: return
	var h = HTTPRequest.new()
	h.set_tls_options(TLSOptions.client_unsafe())
	add_child(h)
	h.request(u)
	
	var r = await h.request_completed
	h.queue_free()
	
	if r[1] == 200:
		var i = Image.new()
		if i.load_jpg_from_buffer(r[3]) != OK:
			if i.load_png_from_buffer(r[3]) != OK:
				i.load_webp_from_buffer(r[3])
		user_data.avatar = ImageTexture.create_from_image(i)
		emit_signal("state_changed")

func _check_remote():
	if not token or not repo_name: return
	var sha = await _get_sha(branch)
	if sha and last_known_sha and sha != last_known_sha:
		emit_signal("remote_update_detected")

func _log(m, c): 
	emit_signal("log_msg", m, c)
	print("[GitPro] ", m)

func _finish(s, m): 
	_log(m, Color.GREEN if s else Color.RED)
	emit_signal("operation_done", s)

func _load_cfg():
	var c = ConfigFile.new()
	if c.load(USER_CFG) == OK:
		token = c.get_value("auth", "token", "").strip_edges()
	if c.load(PROJ_CFG) == OK:
		owner_name = c.get_value("git", "owner", "vovawees").strip_edges()
		repo_name = c.get_value("git", "repo", "GitProConnect").strip_edges()

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
	return "https://github.com/settings/tokens/new?scopes=repo,user,workflow,gist&description=GodotGitPro_Client"

# --- QUEUE ---
var _q_items = []; var _q_res = []; var _q_act = 0; var _q_tot = 0; var _q_up = false
signal _q_done

func _start_queue(i, u) -> Array:
	_q_items = i.duplicate()
	_q_res = []
	_q_tot = i.size()
	_q_up = u
	_q_act = 0
	emit_signal("progress", "Start", 0, _q_tot)
	
	for x in 4: http_busy[x] = false
	_pump()
	await self._q_done
	return _q_res

func _pump():
	if _q_items.is_empty() and _q_act == 0:
		emit_signal("_q_done")
		return
		
	for x in 4:
		if _q_items.is_empty(): break
		if not http_busy[x]:
			_q_act += 1
			http_busy[x] = true
			_run_w(x, _q_items.pop_front())

func _run_w(i, item):
	var req = http_pool[i]
	req.cancel_request()
	var url = "https://api.github.com/repos/%s/%s/git/blobs" % [owner_name, repo_name]
	var err = OK
	
	if _q_up: 
		var f = FileAccess.open(item["path"], FileAccess.READ)
		if f:
			var b64 = Marshalls.raw_to_base64(f.get_buffer(f.get_length()))
			err = req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify({"content": b64, "encoding": "base64"}))
		else: err = FAILED
	else:
		url += "/" + item["sha"]
		err = req.request(url, _headers(), HTTPClient.METHOD_GET)
	
	var _end = func(r):
		if r: _q_res.append(r)
		http_busy[i] = false
		_q_act -= 1
		call_deferred("emit_signal", "progress", "...", _q_tot - _q_items.size() - _q_act, _q_tot)
		call_deferred("_pump")
	
	if err != OK:
		_end.call(null)
		return
	
	var r = await req.request_completed
	if r[1] in [200, 201]:
		var j = JSON.parse_string(r[3].get_string_from_utf8())
		if j:
			if _q_up:
				_end.call({
					"path": item["path"].replace("res://", ""),
					"mode": "100644",
					"type": "blob",
					"sha": j["sha"]
				})
			else:
				_end.call({
					"path": item["path"],
					"data": Marshalls.base64_to_raw(j["content"])
				})
		else:
			_end.call(null)
	else:
		_end.call(null)
