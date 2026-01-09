@tool
extends Control

var core: GitProCore

# --- UI ЭЛЕМЕНТЫ ---
var main_vbox: VBoxContainer
var body_panel: PanelContainer
var files_root: VBoxContainer
var settings_root: VBoxContainer
var login_root: CenterContainer

var tree: Tree
var search: LineEdit
var check_all: CheckBox
var btn_push: Button
var input_comment: LineEdit
var lbl_status: Label
var lbl_user: Label
var tex_avatar: TextureRect

var inp_owner: LineEdit
var inp_repo: LineEdit
var inp_token: LineEdit
var btn_update: Button
var btn_create_git: Button 

# Таймер для автообновления
var refresh_timer: Timer
var is_scanning = false # Флаг, чтобы не запускать два скана одновременно

var icons = {}

func _init(_core):
	core = _core

func _ready():
	_load_icons()
	for c in get_children(): c.free()
	
	# Создаем таймер для "мягкого" обновления
	refresh_timer = Timer.new()
	refresh_timer.wait_time = 1.5 # Ждем 1.5 секунды после изменений, прежде чем обновить
	refresh_timer.one_shot = true
	refresh_timer.timeout.connect(_on_auto_refresh_timeout)
	add_child(refresh_timer)
	
	_create_ui()
	
	if core:
		if not core.log_message.is_connected(_on_log): core.log_message.connect(_on_log)
		if not core.user_profile_loaded.is_connected(_on_user): core.user_profile_loaded.connect(_on_user)
		if not core.operation_progress.is_connected(_on_progress): core.operation_progress.connect(_on_progress)
		if not core.operation_finished.is_connected(_on_finished): core.operation_finished.connect(_on_finished)
		if not core.update_status.is_connected(_on_update_stat): core.update_status.connect(_on_update_stat)
		
		# ПОДКЛЮЧАЕМ АВТООБНОВЛЕНИЕ ОТ GODOT
		var fs = EditorInterface.get_resource_filesystem()
		if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
			fs.filesystem_changed.connect(_on_filesystem_changed)
		
		await get_tree().process_frame
		_update_state()

func _load_icons():
	var base = EditorInterface.get_base_control()
	var get_ico = func(n): return base.get_theme_icon(n, "EditorIcons")
	
	icons["folder"] = get_ico.call("Folder")
	icons["save"] = get_ico.call("Save")
	icons["tools"] = get_ico.call("Tools")
	icons["reload"] = get_ico.call("Reload")
	icons["search"] = get_ico.call("Search")
	icons["back"] = get_ico.call("Back")
	icons["user"] = get_ico.call("GuiVisibilityVisible")
	icons["warning"] = get_ico.call("NodeWarning")
	icons["cloud"] = get_ico.call("AssetLib")
	icons["add"] = get_ico.call("Add")
	
	icons["file"] = get_ico.call("File")
	icons["script"] = get_ico.call("Script")
	icons["scene"] = get_ico.call("PackedScene")
	icons["image"] = get_ico.call("Texture")
	icons["audio"] = get_ico.call("AudioStreamWAV")
	icons["text"] = get_ico.call("Label")

func _get_icon_for_file(file_name: String) -> Texture2D:
	var ext = file_name.get_extension().to_lower()
	match ext:
		"gd", "cs": return icons["script"]
		"tscn", "scn", "tres": return icons["scene"]
		"png", "jpg", "svg": return icons["image"]
		"wav", "ogg": return icons["audio"]
		"txt", "md", "cfg", "json": return icons["text"]
	return icons["file"]

func _create_ui():
	var bg = Panel.new()
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	
	main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(PRESET_FULL_RECT)
	add_child(main_vbox)
	
	# HEADER
	var h_cont = PanelContainer.new()
	var h_style = StyleBoxFlat.new()
	h_style.bg_color = Color(0.15, 0.15, 0.15)
	h_style.content_margin_top = 5
	h_style.content_margin_bottom = 5
	h_style.content_margin_left = 10
	h_style.content_margin_right = 10
	h_cont.add_theme_stylebox_override("panel", h_style)
	main_vbox.add_child(h_cont)
	
	var hbox = HBoxContainer.new()
	h_cont.add_child(hbox)
	
	tex_avatar = TextureRect.new()
	tex_avatar.custom_minimum_size = Vector2(24, 24)
	tex_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex_avatar.texture = icons["user"]
	hbox.add_child(tex_avatar)
	
	lbl_user = Label.new()
	lbl_user.text = "User"
	hbox.add_child(lbl_user)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(spacer)
	
	var btn_set = Button.new()
	btn_set.icon = icons["tools"]
	btn_set.flat = true
	btn_set.pressed.connect(func(): _show("settings"))
	hbox.add_child(btn_set)
	
	# BODY
	body_panel = PanelContainer.new()
	body_panel.size_flags_vertical = SIZE_EXPAND_FILL
	main_vbox.add_child(body_panel)
	
	_ui_files()
	_ui_settings()
	_ui_login()
	
	# FOOTER
	var f_cont = PanelContainer.new()
	var f_style = StyleBoxFlat.new()
	f_style.content_margin_left = 10
	f_style.content_margin_right = 10
	f_style.content_margin_top = 10
	f_style.content_margin_bottom = 10
	f_style.bg_color = Color(0.1, 0.1, 0.1)
	f_cont.add_theme_stylebox_override("panel", f_style)
	main_vbox.add_child(f_cont)
	
	var f_vbox = VBoxContainer.new()
	f_cont.add_child(f_vbox)
	
	input_comment = LineEdit.new()
	input_comment.placeholder_text = "Комментарий..."
	f_vbox.add_child(input_comment)
	
	btn_push = Button.new()
	btn_push.text = " ОТПРАВИТЬ"
	btn_push.icon = icons["save"]
	btn_push.custom_minimum_size.y = 50
	btn_push.pressed.connect(_on_push)
	f_vbox.add_child(btn_push)
	
	lbl_status = Label.new()
	lbl_status.text = "Готов"
	lbl_status.modulate = Color.GRAY
	lbl_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	f_vbox.add_child(lbl_status)

func _ui_files():
	files_root = VBoxContainer.new()
	files_root.size_flags_vertical = SIZE_EXPAND_FILL
	body_panel.add_child(files_root)
	
	var tools = HBoxContainer.new()
	files_root.add_child(tools)
	
	check_all = CheckBox.new()
	check_all.button_pressed = true
	check_all.toggled.connect(_on_check_all)
	tools.add_child(check_all)
	
	search = LineEdit.new()
	search.placeholder_text = "Поиск..."
	search.size_flags_horizontal = SIZE_EXPAND_FILL
	search.text_changed.connect(_on_search)
	tools.add_child(search)
	
	var b_ref = Button.new()
	b_ref.icon = icons["reload"]
	b_ref.tooltip_text = "Обновить список файлов"
	b_ref.pressed.connect(_refresh)
	tools.add_child(b_ref)
	
	tree = Tree.new()
	tree.size_flags_vertical = SIZE_EXPAND_FILL
	tree.size_flags_horizontal = SIZE_EXPAND_FILL
	tree.custom_minimum_size.y = 0 
	tree.add_theme_constant_override("h_separation", 0)
	tree.columns = 2
	tree.set_column_expand(0, false)
	tree.set_column_custom_minimum_width(0, 22) 
	tree.set_column_expand(1, true)
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW 
	tree.item_selected.connect(_on_tree_click)
	files_root.add_child(tree)

func _ui_settings():
	settings_root = VBoxContainer.new()
	settings_root.visible = false
	settings_root.size_flags_vertical = SIZE_EXPAND_FILL
	body_panel.add_child(settings_root)
	
	var m = MarginContainer.new()
	m.add_theme_constant_override("margin_left", 20)
	m.add_theme_constant_override("margin_right", 20)
	m.add_theme_constant_override("margin_top", 20)
	settings_root.add_child(m)
	
	var content = VBoxContainer.new()
	m.add_child(content)
	
	var l = Label.new()
	l.text = "НАСТРОЙКИ"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(l)
	content.add_child(HSeparator.new())
	
	content.add_child(_lbl("Владелец:"))
	inp_owner = LineEdit.new()
	content.add_child(inp_owner)
	
	content.add_child(_lbl("Репозиторий:"))
	inp_repo = LineEdit.new()
	content.add_child(inp_repo)
	
	var b_save = Button.new()
	b_save.text = "СОХРАНИТЬ КОНФИГ"
	b_save.custom_minimum_size.y = 40
	b_save.pressed.connect(_save_conf)
	content.add_child(b_save)
	
	content.add_child(HSeparator.new())
	
	btn_create_git = Button.new()
	btn_create_git.text = "Создать .gitignore"
	btn_create_git.icon = icons["add"]
	btn_create_git.pressed.connect(_create_gitignore)
	content.add_child(btn_create_git)
	
	btn_update = Button.new()
	btn_update.text = "Обновить плагин"
	btn_update.icon = icons["cloud"]
	btn_update.pressed.connect(_on_update_plugin)
	content.add_child(btn_update)
	
	content.add_child(Control.new())
	
	var b_back = Button.new()
	b_back.text = "Назад"
	b_back.icon = icons["back"]
	b_back.pressed.connect(func(): _show("files"))
	content.add_child(b_back)
	
	content.add_child(HSeparator.new())
	var b_logout = Button.new()
	b_logout.text = "Выйти"
	b_logout.modulate = Color(1, 0.4, 0.4)
	b_logout.pressed.connect(_logout)
	content.add_child(b_logout)

func _ui_login():
	login_root = CenterContainer.new()
	login_root.visible = false
	body_panel.add_child(login_root)
	
	var bg = Panel.new()
	bg.custom_minimum_size = Vector2(2000, 2000)
	var s = StyleBoxFlat.new()
	s.bg_color = Color(0,0,0, 0.95)
	bg.add_theme_stylebox_override("panel", s)
	login_root.add_child(bg)
	
	var box = VBoxContainer.new()
	box.custom_minimum_size = Vector2(300, 0)
	login_root.add_child(box)
	
	var t = Label.new()
	t.text = "GitPro Connect"
	t.add_theme_font_size_override("font_size", 24)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	
	var b_link = Button.new()
	b_link.text = "Получить токен (Classic)"
	b_link.modulate = Color(0.6, 1, 0.6)
	b_link.custom_minimum_size.y = 45
	b_link.pressed.connect(func(): OS.shell_open("https://github.com/settings/tokens/new?scopes=repo,workflow,gist,user&description=GodotGitPro"))
	box.add_child(b_link)
	
	inp_token = LineEdit.new()
	inp_token.placeholder_text = "Вставь токен..."
	inp_token.secret = true
	box.add_child(inp_token)
	
	var b_go = Button.new()
	b_go.text = "ВОЙТИ"
	b_go.custom_minimum_size.y = 45
	b_go.pressed.connect(_do_login)
	box.add_child(b_go)

func _lbl(t):
	var l = Label.new()
	l.text = t
	return l

# ==============================================================================
# ЛОГИКА
# ==============================================================================

func _update_state():
	if core.github_token == "":
		_show("login")
	else:
		if lbl_user: lbl_user.text = core.user_login if core.user_login else "User"
		if core.user_avatar_texture and tex_avatar: tex_avatar.texture = core.user_avatar_texture
		if btn_create_git: btn_create_git.visible = not core.utils.has_gitignore()
		
		if core.repo_name == "" or core.repo_owner == "":
			_show("settings_force")
		else:
			_show("files")
			if inp_owner: inp_owner.text = core.repo_owner
			if inp_repo: inp_repo.text = core.repo_name

func _show(what):
	if not files_root or not settings_root or not login_root: return
	files_root.visible = false
	settings_root.visible = false
	login_root.visible = false
	
	if what == "files":
		files_root.visible = true
		_refresh()
	elif what == "settings":
		settings_root.visible = true
		if btn_create_git: btn_create_git.visible = not core.utils.has_gitignore()
	elif what == "settings_force":
		settings_root.visible = true
	elif what == "login":
		login_root.visible = true

# --- АВТООБНОВЛЕНИЕ ---

func _on_filesystem_changed():
	# Если мы сейчас ничего не загружаем и таймер не запущен
	if not is_scanning and refresh_timer.is_stopped() and files_root.visible:
		refresh_timer.start()

func _on_auto_refresh_timeout():
	_refresh()

func _refresh():
	if is_scanning: return
	is_scanning = true
	_build_tree(search.text)
	is_scanning = false

func _on_search(txt):
	_build_tree(txt)

func _build_tree(filter):
	if not tree: return
	tree.clear()
	var root = tree.create_item()
	var cnt = _scan("res://", root, filter.to_lower())
	if lbl_status and btn_push and not btn_push.disabled:
		lbl_status.text = "Найдено: %s" % cnt
		lbl_status.modulate = Color.GRAY

# ГЛАВНЫЙ СКАНЕР С ЗАЩИТОЙ
# ... (начало файла стандартное) ...

# В функции _scan добавляем проверку в самом начале цикла и перед обращением к utils
func _scan(path, parent, filter):
	# ЗАЩИТА ОТ ВЫЛЕТА (Если плагин перезагружается)
	if not is_instance_valid(core): return 0
	
	var dir = DirAccess.open(path)
	if not dir: return 0
	dir.list_dir_begin()
	var file = dir.get_next()
	
	var f_list = []
	var d_list = []
	
	while file != "":
		if not is_instance_valid(core): return 0 # Еще одна проверка для надежности
		
		if file == "." or file == "..":
			file = dir.get_next()
			continue
		
		# Обращение к utils теперь безопасно
		if core.utils and file in core.utils.HARD_IGNORE_DIRS:
			file = dir.get_next()
			continue
			
		if file.begins_with(".") and file != ".gitignore":
			file = dir.get_next()
			continue
			
		if file.ends_with(".import") or file.ends_with(".uid"):
			file = dir.get_next()
			continue

		var full = path.path_join(file)
		
		if core.utils and core.utils.is_ignored(full):
			file = dir.get_next()
			continue
			
		if dir.current_is_dir():
			d_list.append([file, full])
		else:
			f_list.append([file, full])
		file = dir.get_next()
	
	var c = 0
	for d in d_list:
		var it = tree.create_item(parent)
		it.set_text(1, d[0])
		it.set_icon(1, icons["folder"])
		it.set_selectable(0, false)
		it.set_selectable(1, false)
		var inside = _scan(d[1], it, filter)
		if filter != "" and inside == 0:
			parent.remove_child(it)
		else:
			it.collapsed = (filter == "")
			c += inside
	
	for f in f_list:
		var nm: String = f[0]
		var ph = f[1]
		if filter == "" or filter in nm.to_lower():
			var it = tree.create_item(parent)
			it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			it.set_editable(0, true)
			if check_all: it.set_checked(0, check_all.button_pressed)
			it.set_metadata(0, ph)
			it.set_icon(1, _get_icon_for_file(nm))
			it.set_text(1, nm)
			it.set_selectable(1, true)
			c += 1
	return c

func _on_tree_click():
	var it = tree.get_selected()
	if not it: return
	if tree.get_selected_column() == 1:
		if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			var val = not it.is_checked(0)
			it.set_checked(0, val)
			it.deselect(1)

func _on_check_all(on):
	_rec_chk(tree.get_root(), on)

func _rec_chk(it, on):
	if not it: return
	if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
		it.set_checked(0, on)
	var k = it.get_first_child()
	while k:
		_rec_chk(k, on)
		k = k.get_next()

# --- ACTIONS ---

func _do_login():
	if inp_token.text != "":
		core.save_user_auth(inp_token.text)
		_update_state()

func _logout():
	core.save_user_auth("")
	core.user_login = ""
	_update_state()

func _save_conf():
	var o = inp_owner.text
	var r = inp_repo.text
	if o != "" and r != "":
		core.save_project_config(o, r)
		_update_state()

func _create_gitignore():
	core.utils.create_default_gitignore()
	if btn_create_git: btn_create_git.visible = false
	_refresh()

func _on_update_plugin():
	core.check_and_update()

func _on_push():
	var lst = []
	_get_sel(tree.get_root(), lst)
	if lst.is_empty():
		lbl_status.text = "Пусто!"
		lbl_status.modulate = Color.RED
		return
	var msg = input_comment.text
	if msg == "": msg = "Update from Godot"
	btn_push.disabled = true
	core.push_batch(lst, msg)

func _get_sel(it, lst):
	if not it: return
	if it.is_checked(0) and it.get_metadata(0):
		lst.append(it.get_metadata(0))
	var k = it.get_first_child()
	while k:
		_get_sel(k, lst)
		k = k.get_next()

func _on_log(m, c):
	if lbl_status:
		lbl_status.text = m
		lbl_status.modulate = c

func _on_user(l, t):
	if lbl_user and l: lbl_user.text = l
	if tex_avatar and t: tex_avatar.texture = t

func _on_progress(cur, total, step):
	if btn_push: btn_push.text = "%s (%s/%s)" % [step, cur, total]
	if lbl_status:
		lbl_status.text = "%s..." % step
		lbl_status.modulate = Color.YELLOW

func _on_finished(success):
	if btn_push:
		btn_push.text = " ОТПРАВИТЬ"
		btn_push.disabled = false
	input_comment.text = ""
	if success:
		lbl_status.text = "Готово!"
		lbl_status.modulate = Color.GREEN
		_refresh()
	else:
		lbl_status.text = "Ошибка!"
		lbl_status.modulate = Color.RED

func _on_update_stat(msg):
	if btn_update: btn_update.text = msg
