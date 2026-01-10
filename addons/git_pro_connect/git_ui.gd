@tool
extends Control

var core
var main_col: VBoxContainer
var pages = {}; var ui_refs = {}; var icons = {}

# Диалоги и Окна
var diff_dialog: Window
var diff_local: CodeEdit; var diff_remote: CodeEdit
var issue_create_dialog: ConfirmationDialog
var branch_manager_dialog: AcceptDialog
var issue_viewer_dialog: Window
var file_context_menu: PopupMenu # Новое меню

# Данные для Viewer
var current_issue_num = 0

func _init(_core): core = _core
func _ready(): 
	_load_icons()
	_create_layout()
	_setup_dialogs()
	_connect_signals()
	await get_tree().process_frame
	_refresh_view()

func _load_icons():
	var g = func(n): return EditorInterface.get_editor_theme().get_icon(n, "EditorIcons")
	icons = {
		"folder": g.call("Folder"), "file": g.call("File"), "script": g.call("Script"), 
		"scene": g.call("PackedScene"), "reload": g.call("Reload"), "gear": g.call("Tools"),
		"user": g.call("Skeleton2D"), "sync": g.call("AssetLib"), "branch": g.call("GraphNode"), 
		"issue": g.call("Error"), "gist": g.call("ScriptCreate"), "add": g.call("Add"), 
		"remove": g.call("Remove"), "lock": g.call("CryptoKey"), "clip": g.call("ActionCopy"),
		"chat": g.call("String"), "web": g.call("ExternalLink")
	}

func _connect_signals():
	if !core: return
	core.log_msg.connect(func(m, c): if ui_refs.has("status"): ui_refs.status.text = m; ui_refs.status.modulate = c)
	core.progress.connect(func(s, c, t): if ui_refs.has("sync_btn"): ui_refs.sync_btn.text = "%s (%d/%d)" % [s, c, t]; ui_refs.sync_btn.disabled=true)
	core.operation_done.connect(func(s): 
		if ui_refs.has("sync_btn"): 
			ui_refs.sync_btn.disabled=false; ui_refs.sync_btn.text="СИНХРОНИЗИРОВАТЬ"; ui_refs.sync_btn.modulate=Color.WHITE; ui_refs.comment.text=""
			_refresh_file_list()
	)
	core.state_changed.connect(_refresh_view)
	core.branches_loaded.connect(_update_branches)
	core.history_loaded.connect(_update_history)
	core.blob_content_loaded.connect(_show_diff_remote)
	core.issues_loaded.connect(_update_issues)
	core.issue_updated.connect(func(): issue_create_dialog.hide(); if issue_viewer_dialog.visible: core.fetch_issue_comments(current_issue_num))
	core.gists_loaded.connect(_update_gists)
	core.gist_content_loaded.connect(_show_gist_content)
	core.issue_comments_loaded.connect(_update_issue_chat)
	core.file_reverted.connect(func(p): _refresh_file_list()) # Обновляем дерево после отката
	
	var fs = EditorInterface.get_resource_filesystem()
	if !fs.filesystem_changed.is_connected(_on_fs_changed): fs.filesystem_changed.connect(_on_fs_changed)

func _on_fs_changed(): if pages.has("files") and pages["files"].visible: _refresh_file_list()

func _create_layout():
	for c in get_children(): c.queue_free()
	var bg=Panel.new(); bg.set_anchors_preset(15); add_child(bg)
	main_col=VBoxContainer.new(); main_col.set_anchors_preset(15); add_child(main_col)
	
	# HEADER
	var head=HBoxContainer.new(); var m=MarginContainer.new()
	m.add_theme_constant_override("margin_left",8); m.add_theme_constant_override("margin_top",5); m.add_theme_constant_override("margin_right",8)
	m.add_child(head); main_col.add_child(m)
	ui_refs.avatar=TextureRect.new(); ui_refs.avatar.custom_minimum_size=Vector2(24,24); ui_refs.avatar.expand_mode=1; ui_refs.avatar.stretch_mode=5; ui_refs.avatar.texture=icons.user
	ui_refs.username=Label.new(); ui_refs.username.text="Гость"
	
	# BRANCH CONTROLS
	var hb_branch = HBoxContainer.new()
	ui_refs.branch_opt=OptionButton.new(); ui_refs.branch_opt.item_selected.connect(_on_branch_select); ui_refs.branch_opt.size_flags_horizontal = 3
	var btn_add_br = Button.new(); btn_add_br.icon = icons.add; btn_add_br.tooltip_text = "Создать ветку"
	btn_add_br.pressed.connect(func(): _input_dialog("Новая ветка", func(t): core.create_branch(t)))
	var btn_manage_br = Button.new(); btn_manage_br.icon = icons.gear; btn_manage_br.tooltip_text = "Управление ветками (Удаление)"; btn_manage_br.pressed.connect(_show_branch_manager)
	
	hb_branch.add_child(ui_refs.branch_opt); hb_branch.add_child(btn_add_br); hb_branch.add_child(btn_manage_br)
	hb_branch.size_flags_horizontal = 3
	var btn_cfg=Button.new(); btn_cfg.icon=icons.gear; btn_cfg.flat=true; btn_cfg.pressed.connect(func(): _set_page("settings"))
	head.add_child(ui_refs.avatar); head.add_child(ui_refs.username); head.add_child(VSeparator.new()); head.add_child(hb_branch); head.add_child(btn_cfg)
	main_col.add_child(HSeparator.new())

	# BODY & TABS
	var body=PanelContainer.new(); body.size_flags_vertical=3; main_col.add_child(body)
	var p_login=CenterContainer.new(); pages["login"]=p_login; body.add_child(p_login)
	var lb=VBoxContainer.new(); lb.custom_minimum_size.x=250; p_login.add_child(lb)
	var b_get=Button.new(); b_get.text="1. Magic Link"; b_get.icon=icons.lock; b_get.pressed.connect(func(): OS.shell_open(core.get_magic_link()))
	var hb_tok=HBoxContainer.new(); var t_tok=LineEdit.new(); t_tok.placeholder_text="2. Token..."; t_tok.secret=true; t_tok.size_flags_horizontal=3
	var b_paste=Button.new(); b_paste.icon=icons.clip; b_paste.pressed.connect(func(): t_tok.text=DisplayServer.clipboard_get(); core.save_token(t_tok.text))
	hb_tok.add_child(t_tok); hb_tok.add_child(b_paste)
	var b_log=Button.new(); b_log.text="ВОЙТИ"; b_log.modulate=Color.GREEN; b_log.pressed.connect(func(): core.save_token(t_tok.text))
	lb.add_child(Label.new()); lb.get_child(0).text="GitPro v11.0"; lb.get_child(0).horizontal_alignment=1; lb.add_child(b_get); lb.add_child(hb_tok); lb.add_child(b_log)
	
	var tabs=TabContainer.new(); pages["files"]=tabs; body.add_child(tabs)
	
	# TAB: FILES
	var t_files=VBoxContainer.new(); t_files.name="Файлы"; tabs.add_child(t_files)
	var file_tools = HBoxContainer.new()
	var cb_all = CheckBox.new(); cb_all.text = "Выбрать все"; cb_all.button_pressed = true; cb_all.toggled.connect(func(v): if ui_refs.has("tree"): _set_checked_recursive(ui_refs.tree.get_root(), v))
	var b_refresh = Button.new(); b_refresh.icon = icons.reload; b_refresh.flat = true; b_refresh.pressed.connect(_refresh_file_list)
	file_tools.add_child(cb_all); file_tools.add_child(Control.new()); file_tools.get_child(1).size_flags_horizontal=3; file_tools.add_child(b_refresh); t_files.add_child(file_tools)
	ui_refs.tree=Tree.new(); ui_refs.tree.size_flags_vertical=3; ui_refs.tree.hide_root=true; ui_refs.tree.columns=2; ui_refs.tree.set_column_expand(0, false); ui_refs.tree.set_column_custom_minimum_width(0, 30); ui_refs.tree.item_activated.connect(_on_file_double_click); 
	ui_refs.tree.item_mouse_selected.connect(_on_tree_rmb) # For Context Menu
	t_files.add_child(ui_refs.tree)
	
	# TAB: HISTORY
	var t_hist=VBoxContainer.new(); t_hist.name="История"; tabs.add_child(t_hist)
	var b_rh=Button.new(); b_rh.text="Обновить"; b_rh.icon=icons.reload; b_rh.pressed.connect(func(): core.fetch_history()); t_hist.add_child(b_rh)
	ui_refs.hist_list=ItemList.new(); ui_refs.hist_list.size_flags_vertical=3; t_hist.add_child(ui_refs.hist_list)
	
	# TAB: ISSUES
	var t_iss=VBoxContainer.new(); t_iss.name="Задачи"; tabs.add_child(t_iss)
	var hb_iss=HBoxContainer.new(); var b_ri=Button.new(); b_ri.text="Обновить"; b_ri.icon=icons.reload; b_ri.pressed.connect(func(): core.fetch_issues()); hb_iss.add_child(b_ri)
	var b_ni=Button.new(); b_ni.text="Новая задача"; b_ni.icon=icons.add; b_ni.pressed.connect(func(): issue_create_dialog.popup_centered())
	hb_iss.add_child(b_ni)
	var cb_auto = CheckBox.new(); cb_auto.text = "Авто-обновление"; cb_auto.toggled.connect(func(v): core.auto_refresh_issues = v); hb_iss.add_child(cb_auto)
	t_iss.add_child(hb_iss)
	ui_refs.iss_list=ItemList.new(); ui_refs.iss_list.size_flags_vertical=3; ui_refs.iss_list.item_activated.connect(_on_issue_click); t_iss.add_child(ui_refs.iss_list)
	
	# TAB: GISTS
	var t_gist=VBoxContainer.new(); t_gist.name="Gists"; tabs.add_child(t_gist)
	var hb_gis=HBoxContainer.new(); var b_rg=Button.new(); b_rg.text="Обновить"; b_rg.icon=icons.reload; b_rg.pressed.connect(func(): core.fetch_gists()); hb_gis.add_child(b_rg)
	t_gist.add_child(hb_gis); ui_refs.gist_list=ItemList.new(); ui_refs.gist_list.size_flags_vertical=3; ui_refs.gist_list.item_activated.connect(_on_gist_click); t_gist.add_child(ui_refs.gist_list)

	# SETTINGS & FOOTER
	var p_set=VBoxContainer.new(); pages["settings"]=p_set; body.add_child(p_set)
	ui_refs.inp_owner=LineEdit.new(); ui_refs.inp_owner.placeholder_text="Owner"; ui_refs.inp_repo=LineEdit.new(); ui_refs.inp_repo.placeholder_text="Repo"
	var b_sv=Button.new(); b_sv.text="Сохранить"; b_sv.pressed.connect(func(): core.save_proj(ui_refs.inp_owner.text, ui_refs.inp_repo.text); _refresh_view())
	var b_bk=Button.new(); b_bk.text="Назад"; b_bk.pressed.connect(func(): _set_page("files"))
	p_set.add_child(Label.new()); p_set.get_child(0).text="Настройки"; p_set.add_child(ui_refs.inp_owner); p_set.add_child(ui_refs.inp_repo); p_set.add_child(b_sv); p_set.add_child(b_bk)

	var foot=VBoxContainer.new(); var fm=MarginContainer.new(); fm.add_theme_constant_override("margin_left",5); fm.add_theme_constant_override("margin_right",5); fm.add_theme_constant_override("margin_bottom",5); fm.add_child(foot); main_col.add_child(fm)
	ui_refs.comment=LineEdit.new(); ui_refs.comment.placeholder_text="Комментарий коммита..."; foot.add_child(ui_refs.comment)
	ui_refs.sync_btn=Button.new(); ui_refs.sync_btn.text="СИНХРОНИЗИРОВАТЬ"; ui_refs.sync_btn.icon=icons.sync; ui_refs.sync_btn.custom_minimum_size.y=35; ui_refs.sync_btn.pressed.connect(_on_sync_click); foot.add_child(ui_refs.sync_btn)
	ui_refs.status=Label.new(); ui_refs.status.text="Готов"; ui_refs.status.modulate=Color.GRAY; ui_refs.status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; foot.add_child(ui_refs.status)
	ui_refs.info_lbl=Label.new(); ui_refs.info_lbl.modulate=Color(0.7,0.7,0.7); ui_refs.info_lbl.add_theme_font_size_override("font_size", 10); ui_refs.info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; foot.add_child(ui_refs.info_lbl)

func _setup_dialogs():
	# Diff
	diff_dialog=Window.new(); diff_dialog.title="Diff"; diff_dialog.initial_position=Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN; diff_dialog.size=Vector2(900,600); diff_dialog.visible=false; diff_dialog.close_requested.connect(func(): diff_dialog.hide())
	var split=HBoxContainer.new(); split.set_anchors_preset(15); diff_dialog.add_child(split)
	diff_remote=CodeEdit.new(); diff_remote.size_flags_horizontal=3; diff_remote.editable=false; diff_local=CodeEdit.new(); diff_local.size_flags_horizontal=3; split.add_child(diff_remote); split.add_child(diff_local); add_child(diff_dialog)
	
	# Issue Create
	issue_create_dialog = ConfirmationDialog.new(); issue_create_dialog.title = "Новая задача"; issue_create_dialog.size = Vector2(400, 300)
	var ivb = VBoxContainer.new(); issue_create_dialog.add_child(ivb)
	var i_ti = LineEdit.new(); i_ti.placeholder_text = "Заголовок"; ivb.add_child(i_ti); var i_bd = TextEdit.new(); i_bd.placeholder_text = "Описание..."; i_bd.size_flags_vertical = 3; ivb.add_child(i_bd)
	issue_create_dialog.confirmed.connect(func(): core.create_issue_api(i_ti.text, i_bd.text); i_ti.clear(); i_bd.clear()); add_child(issue_create_dialog)
	
	# Branch Manager
	branch_manager_dialog = AcceptDialog.new(); branch_manager_dialog.title = "Управление ветками"; branch_manager_dialog.size = Vector2(300, 400)
	var bmv = VBoxContainer.new(); branch_manager_dialog.add_child(bmv)
	bmv.add_child(Label.new()); bmv.get_child(0).text = "Нажмите на корзину для удаления."
	ui_refs.br_list_box = VBoxContainer.new(); bmv.add_child(ui_refs.br_list_box); add_child(branch_manager_dialog)

	# Issue Viewer
	issue_viewer_dialog = Window.new(); issue_viewer_dialog.title = "Просмотр задачи"; issue_viewer_dialog.size = Vector2(500, 600); issue_viewer_dialog.visible = false; issue_viewer_dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN; issue_viewer_dialog.close_requested.connect(func(): issue_viewer_dialog.hide())
	var imain = VBoxContainer.new(); imain.set_anchors_preset(15); issue_viewer_dialog.add_child(imain)
	var itop = HBoxContainer.new(); imain.add_child(itop)
	ui_refs.iv_title = Label.new(); ui_refs.iv_title.size_flags_horizontal = 3; itop.add_child(ui_refs.iv_title)
	ui_refs.iv_state_btn = Button.new(); ui_refs.iv_state_btn.pressed.connect(_on_toggle_issue_state); itop.add_child(ui_refs.iv_state_btn)
	ui_refs.iv_chat = RichTextLabel.new(); ui_refs.iv_chat.size_flags_vertical = 3; ui_refs.iv_chat.bbcode_enabled = true; imain.add_child(ui_refs.iv_chat)
	var ibot = HBoxContainer.new(); imain.add_child(ibot)
	ui_refs.iv_input = LineEdit.new(); ui_refs.iv_input.size_flags_horizontal = 3; ibot.add_child(ui_refs.iv_input)
	var b_snd = Button.new(); b_snd.icon = icons.chat; b_snd.pressed.connect(_on_post_comment); ibot.add_child(b_snd)
	add_child(issue_viewer_dialog)
	
	# Context Menu
	file_context_menu = PopupMenu.new()
	file_context_menu.add_icon_item(icons.reload, "Откатить (Revert)", 0)
	file_context_menu.add_icon_item(icons.web, "Открыть на GitHub", 1)
	file_context_menu.add_icon_item(icons.clip, "Копировать путь", 2)
	file_context_menu.id_pressed.connect(_on_context_menu_action)
	add_child(file_context_menu)

func _refresh_view():
	if !core: return
	_update_info_label()
	if core.token=="": _set_page("login")
	elif core.repo_name=="": ui_refs.inp_owner.text=core.owner_name; ui_refs.inp_repo.text=core.repo_name; _set_page("settings")
	else:
		ui_refs.username.text=core.user_data.name if core.user_data.name else core.user_data.login
		if core.user_data.avatar: ui_refs.avatar.texture=core.user_data.avatar
		core.fetch_branches()
		_set_page("files")

func _update_info_label():
	if !ui_refs.has("info_lbl"): return
	var sha_disp = core.last_known_sha.left(7) if core.last_known_sha else "???"
	ui_refs.info_lbl.text = "Repo: %s/%s | Branch: %s\nLast SHA: %s" % [core.owner_name, core.repo_name, core.branch, sha_disp]

func _set_page(n): for k in pages: pages[k].visible=(k==n); if n=="files": _refresh_file_list()

# === FILES & TREE ===
func _refresh_file_list():
	if !ui_refs.has("tree"): return
	ui_refs.tree.clear(); var root = ui_refs.tree.create_item(); _scan_rec("res://", root)
func _scan_rec(path, parent):
	var dir = DirAccess.open(path); if not dir: return
	dir.list_dir_begin(); var file = dir.get_next(); var items = []
	while file != "":
		if file != "." and file != ".." and !file.begins_with("."):
			var full = path.path_join(file)
			if dir.current_is_dir(): items.append({"n":file,"p":full,"d":true})
			elif !file.ends_with(".uid") and !file.ends_with(".bak"): items.append({"n":file,"p":full,"d":false})
		file = dir.get_next()
	items.sort_custom(func(a,b): return a.d and !b.d)
	for i in items:
		var it = ui_refs.tree.create_item(parent); it.set_text(1, i.n)
		if i.d: it.set_icon(1, icons.folder); it.set_selectable(0, false); _scan_rec(i.p, it)
		else:
			it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK); it.set_checked(0, true); it.set_editable(0, true); it.set_metadata(0, i.p)
			var ext=i.n.get_extension(); it.set_icon(1, icons.script if ["gd","cs"].has(ext) else (icons.scene if ["tscn","tres"].has(ext) else icons.file))

# FIX: Robust Recursive Checked Getter
func _on_sync_click(): 
	var paths=[]; _get_checked(ui_refs.tree.get_root(), paths)
	if paths.is_empty():
		core._finish(false, "Не выбрано ни одного файла.")
		return
	ui_refs.sync_btn.disabled=true; core.smart_sync(paths, ui_refs.comment.text if ui_refs.comment.text else "")

func _get_checked(it: TreeItem, list: Array):
	if !it: return
	if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK and it.is_checked(0):
		list.append(it.get_metadata(0))
	var child = it.get_first_child()
	while child:
		_get_checked(child, list)
		child = child.get_next()

func _set_checked_recursive(it, checked): 
	if !it: return
	if it.get_cell_mode(0)==TreeItem.CELL_MODE_CHECK: it.set_checked(0, checked)
	var c=it.get_first_child(); while c: _set_checked_recursive(c, checked); c=c.get_next()

# === CONTEXT MENU ===
func _on_tree_rmb(pos, button_index):
	if button_index == MOUSE_BUTTON_RIGHT:
		var it = ui_refs.tree.get_selected()
		if it and it.get_metadata(0):
			file_context_menu.position = get_screen_position() + get_local_mouse_position()
			file_context_menu.popup()

func _on_context_menu_action(id):
	var it = ui_refs.tree.get_selected()
	if !it: return
	var path = it.get_metadata(0)
	match id:
		0: core.revert_file(path) # Revert
		1: OS.shell_open("https://github.com/%s/%s/blob/%s/%s" % [core.owner_name, core.repo_name, core.branch, path.replace("res://", "")])
		2: DisplayServer.clipboard_set(path)

func _on_file_double_click():
	var it=ui_refs.tree.get_selected(); if !it or !it.get_metadata(0): return
	var p=it.get_metadata(0); var f=FileAccess.open(p,FileAccess.READ); diff_local.text=f.get_as_text() if f else "Error"
	diff_remote.text="Загрузка..."; diff_dialog.title="Diff: "+p.get_file(); diff_dialog.popup_centered(); core.fetch_blob_content(core._calculate_git_sha(p))

# === BRANCH MANAGER ===
func _update_branches(list, cur):
	ui_refs.branch_opt.clear(); var idx=0
	for b in list: ui_refs.branch_opt.add_item(b); if b==cur: ui_refs.branch_opt.select(idx); idx+=1
	_rebuild_branch_manager_list(list, cur)
	_update_info_label() # Обновляем SHA

func _rebuild_branch_manager_list(list, cur):
	if !ui_refs.has("br_list_box"): return
	for c in ui_refs.br_list_box.get_children(): c.queue_free()
	for b in list:
		var r = HBoxContainer.new(); ui_refs.br_list_box.add_child(r)
		var lbl = Label.new(); lbl.text = b; lbl.size_flags_horizontal=3; r.add_child(lbl)
		if b == cur: lbl.modulate = Color.GREEN; lbl.text += " (Active)"
		else: var btn = Button.new(); btn.icon = icons.remove; btn.flat = true; btn.pressed.connect(func(): core.delete_branch(b)); r.add_child(btn)

func _show_branch_manager(): branch_manager_dialog.popup_centered()
func _on_branch_select(idx): var txt=ui_refs.branch_opt.get_item_text(idx); if txt!=core.branch: core.branch=txt; core.last_known_sha=""; core.fetch_history(); _refresh_file_list()

# === HISTORY & GISTS ===
func _update_history(commits): ui_refs.hist_list.clear(); for c in commits: ui_refs.hist_list.add_item(c["date"]+": "+c["msg"]+" ("+c["author"]+")")
func _update_gists(list): ui_refs.gist_list.clear(); for g in list: var fn=g["files"].values()[0]["filename"]; ui_refs.gist_list.add_item((g["description"] if g["description"] else fn)+" ("+fn+")"); ui_refs.gist_list.set_item_metadata(ui_refs.gist_list.get_item_count()-1, g["id"])
func _on_gist_click(idx): core.get_gist_content(ui_refs.gist_list.get_item_metadata(idx))
func _show_gist_content(fn, content): diff_remote.text=content; diff_local.text=""; diff_local.placeholder_text="Read Only"; diff_dialog.title="Gist: "+fn; diff_dialog.popup_centered()
func _show_diff_remote(c): diff_remote.text = c

# === ISSUE VIEWER ===
func _update_issues(list):
	ui_refs.iss_list.clear()
	for i in list:
		var idx = ui_refs.iss_list.add_item("#"+str(i["number"])+" "+i["title"])
		ui_refs.iss_list.set_item_icon(idx, icons.issue)
		ui_refs.iss_list.set_item_custom_fg_color(idx, Color.GREEN if i["state"]=="open" else Color.RED)
		ui_refs.iss_list.set_item_metadata(idx, i)

func _on_issue_click(idx):
	var data = ui_refs.iss_list.get_item_metadata(idx)
	current_issue_num = data["number"]
	ui_refs.iv_title.text = "#" + str(data["number"]) + ": " + data["title"]
	_update_issue_state_btn(data["state"] == "open")
	ui_refs.iv_chat.clear()
	ui_refs.iv_chat.push_bold(); ui_refs.iv_chat.append_text(data["user"]["login"] + " commented:\n"); ui_refs.iv_chat.pop()
	ui_refs.iv_chat.append_text(data["body"] + "\n\n")
	ui_refs.iv_chat.add_text("------------------------\n")
	issue_viewer_dialog.popup_centered()
	core.fetch_issue_comments(current_issue_num)

func _update_issue_chat(comments):
	for c in comments:
		ui_refs.iv_chat.push_color(Color.CYAN); ui_refs.iv_chat.push_bold()
		ui_refs.iv_chat.append_text(c["user"]["login"] + ": "); ui_refs.iv_chat.pop(); ui_refs.iv_chat.pop()
		ui_refs.iv_chat.append_text(c["body"] + "\n\n")

func _on_post_comment():
	var txt = ui_refs.iv_input.text
	if txt.strip_edges() != "":
		ui_refs.iv_input.text = ""
		core.post_issue_comment(current_issue_num, txt)
		ui_refs.iv_chat.append_text("[i]Posting...[/i]\n")

func _on_toggle_issue_state():
	var is_open = ui_refs.iv_state_btn.text == "Close Issue"
	core.change_issue_state(current_issue_num, is_open)
	ui_refs.iv_state_btn.disabled = true

func _update_issue_state_btn(is_open):
	ui_refs.iv_state_btn.disabled = false
	if is_open: ui_refs.iv_state_btn.text = "Close Issue"; ui_refs.iv_state_btn.modulate = Color.RED
	else: ui_refs.iv_state_btn.text = "Reopen Issue"; ui_refs.iv_state_btn.modulate = Color.GREEN

func _input_dialog(title, cb): var dlg=ConfirmationDialog.new(); dlg.title=title; var l=LineEdit.new(); dlg.add_child(l); add_child(dlg); dlg.popup_centered(Vector2(250,80)); dlg.confirmed.connect(func(): cb.call(l.text); dlg.queue_free())
