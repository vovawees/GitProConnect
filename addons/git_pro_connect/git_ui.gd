@tool
extends Control

var core: GitProCore
var main_col: VBoxContainer
var pages = {} 
var ui_refs = {} 
var icons = {}

func _init(_core): core = _core

func _ready():
	_load_icons()
	_create_layout()
	_connect_signals()
	# Ждем кадр, чтобы core успел подгрузить данные
	await get_tree().process_frame
	_refresh_view()

func _load_icons():
	var th = EditorInterface.get_editor_theme()
	var g = func(n): return th.get_icon(n, "EditorIcons")
	
	icons = {
		"folder": g.call("Folder"), "file": g.call("File"),
		"script": g.call("Script"), "scene": g.call("PackedScene"),
		"reload": g.call("Reload"), "gear": g.call("Tools"),
		"user": g.call("Skeleton2D"), 
		"save": g.call("Save"), "down": g.call("MoveDown"), 
		"lock": g.call("CryptoKey"), "clip": g.call("ActionCopy")
	}

func _connect_signals():
	if not core: return
	# Проверяем наличие ключей перед обращением
	core.log_msg.connect(func(m, c): 
		if ui_refs.has("status"): ui_refs.status.text = m; ui_refs.status.modulate = c
	)
	core.progress.connect(func(s, c, t): 
		if ui_refs.has("push_btn"): ui_refs.push_btn.text = "%s (%d/%d)" % [s, c, t]; ui_refs.push_btn.disabled=true
	)
	core.operation_done.connect(func(s): 
		if ui_refs.has("push_btn"):
			ui_refs.push_btn.disabled=false; ui_refs.pull_btn.disabled=false; ui_refs.push_btn.text="ОТПРАВИТЬ (PUSH)"
			_refresh_file_list()
	)
	core.state_changed.connect(_refresh_view)

func _create_layout():
	for c in get_children(): c.queue_free()
	
	var bg = Panel.new(); bg.set_anchors_preset(PRESET_FULL_RECT); add_child(bg)
	main_col = VBoxContainer.new(); main_col.set_anchors_preset(PRESET_FULL_RECT); add_child(main_col)
	
	# === HEADER ===
	var head = HBoxContainer.new()
	var m = MarginContainer.new(); m.add_theme_constant_override("margin_left", 8); m.add_theme_constant_override("margin_top", 5); m.add_theme_constant_override("margin_right", 8); m.add_child(head)
	main_col.add_child(m)
	
	ui_refs.avatar = TextureRect.new(); ui_refs.avatar.custom_minimum_size=Vector2(24,24); ui_refs.avatar.expand_mode=TextureRect.EXPAND_IGNORE_SIZE; ui_refs.avatar.texture=icons.user
	ui_refs.username = Label.new(); ui_refs.username.text = "Гость"
	var btn_cfg = Button.new(); btn_cfg.icon = icons.gear; btn_cfg.flat=true; btn_cfg.pressed.connect(func(): _set_page("settings"))
	
	head.add_child(ui_refs.avatar); head.add_child(ui_refs.username)
	head.add_child(Control.new()); head.get_child(-1).size_flags_horizontal=SIZE_EXPAND_FILL
	head.add_child(btn_cfg)
	main_col.add_child(HSeparator.new())

	# === BODY ===
	var body = PanelContainer.new(); body.size_flags_vertical=SIZE_EXPAND_FILL; main_col.add_child(body)
	
	# PAGE 1: LOGIN
	var p_login = CenterContainer.new(); pages["login"]=p_login; body.add_child(p_login)
	var lb = VBoxContainer.new(); lb.custom_minimum_size.x = 250; p_login.add_child(lb)
	
	var b_get = Button.new(); b_get.text="1. Получить токен"; b_get.icon=icons.lock; b_get.pressed.connect(func(): OS.shell_open(core.get_magic_link()))
	
	var hb_tok = HBoxContainer.new()
	var t_tok = LineEdit.new(); t_tok.placeholder_text="2. Токен сюда..."; t_tok.secret=true; t_tok.size_flags_horizontal=SIZE_EXPAND_FILL
	var b_paste = Button.new(); b_paste.icon=icons.clip; b_paste.pressed.connect(func(): t_tok.text=DisplayServer.clipboard_get(); core.save_token(t_tok.text))
	hb_tok.add_child(t_tok); hb_tok.add_child(b_paste)
	
	var b_login = Button.new(); b_login.text="ВОЙТИ"; b_login.modulate=Color.GREEN; b_login.pressed.connect(func(): core.save_token(t_tok.text))
	lb.add_child(Label.new()); lb.get_child(0).text="GitPro Connect"; lb.get_child(0).horizontal_alignment=1
	lb.add_child(b_get); lb.add_child(hb_tok); lb.add_child(b_login)
	
	# PAGE 2: FILES
	var p_files = VBoxContainer.new(); pages["files"]=p_files; body.add_child(p_files)
	var tb = HBoxContainer.new()
	var b_ref = Button.new(); b_ref.icon=icons.reload; b_ref.pressed.connect(_refresh_file_list)
	tb.add_child(b_ref)
	p_files.add_child(tb)
	ui_refs.tree = Tree.new(); ui_refs.tree.size_flags_vertical=3; ui_refs.tree.hide_root=true; ui_refs.tree.columns=2; ui_refs.tree.set_column_expand(0, false); ui_refs.tree.set_column_custom_minimum_width(0, 30)
	p_files.add_child(ui_refs.tree)
	
	# PAGE 3: SETTINGS
	var p_set = VBoxContainer.new(); pages["settings"]=p_set; body.add_child(p_set)
	ui_refs.inp_owner = LineEdit.new(); ui_refs.inp_owner.placeholder_text="Owner"
	ui_refs.inp_repo = LineEdit.new(); ui_refs.inp_repo.placeholder_text="Repo"
	var b_sv = Button.new(); b_sv.text="Сохранить"; b_sv.pressed.connect(func(): core.save_proj(ui_refs.inp_owner.text, ui_refs.inp_repo.text); _refresh_view())
	var b_bk = Button.new(); b_bk.text="Назад"; b_bk.pressed.connect(func(): _set_page("files"))
	var b_out = Button.new(); b_out.text="Выход"; b_out.modulate=Color.RED; b_out.pressed.connect(func(): core.save_token(""); _refresh_view())
	p_set.add_child(Label.new()); p_set.get_child(0).text="Настройки"
	p_set.add_child(ui_refs.inp_owner); p_set.add_child(ui_refs.inp_repo); p_set.add_child(b_sv); p_set.add_child(b_out); p_set.add_child(b_bk)

	# === FOOTER (ИСПРАВЛЕНО) ===
	var foot = VBoxContainer.new()
	var fm = MarginContainer.new(); fm.add_theme_constant_override("margin_left",5); fm.add_theme_constant_override("margin_right",5); fm.add_theme_constant_override("margin_bottom",5); fm.add_child(foot)
	main_col.add_child(fm)
	
	ui_refs.comment = LineEdit.new(); ui_refs.comment.placeholder_text="Комментарий..."
	foot.add_child(ui_refs.comment)
	
	var act = HBoxContainer.new()
	ui_refs.pull_btn = Button.new(); ui_refs.pull_btn.text="СКАЧАТЬ"; ui_refs.pull_btn.icon=icons.down; ui_refs.pull_btn.size_flags_horizontal=3; ui_refs.pull_btn.pressed.connect(func(): ui_refs.pull_btn.disabled=true; core.pull_safe())
	ui_refs.push_btn = Button.new(); ui_refs.push_btn.text="ОТПРАВИТЬ"; ui_refs.push_btn.icon=icons.save; ui_refs.push_btn.size_flags_horizontal=3; ui_refs.push_btn.pressed.connect(_on_push)
	act.add_child(ui_refs.pull_btn); act.add_child(ui_refs.push_btn)
	foot.add_child(act) # <-- Эта строка возвращает кнопки на место
	
	ui_refs.status = Label.new(); ui_refs.status.text="Готов"; ui_refs.status.modulate=Color.GRAY
	foot.add_child(ui_refs.status) # <-- Создаем лейбл ПОСЛЕ кнопок

func _refresh_view():
	if not core: return
	if core.token == "":
		_set_page("login")
	elif core.repo_name == "":
		ui_refs.inp_owner.text = core.owner_name
		ui_refs.inp_repo.text = core.repo_name
		_set_page("settings")
	else:
		if core.user_data.get("name"): 
			ui_refs.username.text = core.user_data.name
		else:
			ui_refs.username.text = core.user_data.get("login", "Гость")
			
		if core.user_data.get("avatar"): ui_refs.avatar.texture = core.user_data.avatar
		_set_page("files")

func _set_page(n):
	for k in pages: pages[k].visible = (k == n)
	if n == "files": _refresh_file_list()

func _refresh_file_list():
	if not ui_refs.has("tree"): return
	ui_refs.tree.clear()
	var root = ui_refs.tree.create_item()
	_scan_rec("res://", root)

func _scan_rec(path, parent):
	var dir = DirAccess.open(path)
	if not dir: return
	dir.list_dir_begin()
	var file = dir.get_next()
	var files = []
	var dirs = []
	
	while file != "":
		if file in [".", "..", ".godot", ".git", "android"]: file = dir.get_next(); continue
		var full = path.path_join(file)
		if dir.current_is_dir(): dirs.append({n=file, p=full})
		else: if not file.ends_with(".uid") and not file.ends_with(core.BACKUP_EXT): files.append({n=file, p=full})
		file = dir.get_next()
		
	for d in dirs:
		var it = ui_refs.tree.create_item(parent); it.set_text(1, d.n); it.set_icon(1, icons.folder); it.set_selectable(0, false); _scan_rec(d.p, it)
	for f in files:
		var it = ui_refs.tree.create_item(parent); it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK); it.set_checked(0, true); it.set_editable(0, true); it.set_text(1, f.n); it.set_metadata(0, f.p)
		var ext = f.n.get_extension()
		if ext in ["gd", "cs"]: it.set_icon(1, icons.script)
		elif ext in ["tscn", "tres"]: it.set_icon(1, icons.scene)
		else: it.set_icon(1, icons.file)

func _on_push():
	var paths = []
	_get_checked(ui_refs.tree.get_root(), paths)
	if paths.is_empty(): ui_refs.status.text="Пусто"; return
	ui_refs.push_btn.disabled=true
	core.push_safe(paths, ui_refs.comment.text if ui_refs.comment.text else "Update")

func _get_checked(it, list):
	if not it: return
	if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK and it.is_checked(0): list.append(it.get_metadata(0))
	var ch = it.get_first_child()
	while ch: _get_checked(ch, list); ch = ch.get_next()
