@tool
extends RefCounted
class_name GitUtils

var ignored_exts = {}
var ignored_paths = []

func load_gitignore():
	ignored_exts.clear()
	ignored_paths.clear()
	
	if FileAccess.file_exists("res://.gitignore"):
		var f = FileAccess.open("res://.gitignore", FileAccess.READ)
		while not f.eof_reached():
			var line = f.get_line().strip_edges()
			if line == "" or line.begins_with("#"): continue
			if line.begins_with("*."):
				ignored_exts[line.substr(2)] = true
			else:
				ignored_paths.append(line)
	else:
		# Default settings
		ignored_exts = {"tmp": true, "import": true}
		ignored_paths = [".godot/", ".import/", "export_presets.cfg"]

func is_ignored(path: String) -> bool:
	# path приходит как res://folder/file.ext
	var rel = path.replace("res://", "")
	var fname = rel.get_file()
	
	if fname.ends_with(".uid"): return true
	
	var ext = fname.get_extension()
	if ignored_exts.has(ext): return true
	
	for rule in ignored_paths:
		if rule.ends_with("/"): # Это папка
			if rel.begins_with(rule): return true
		elif rel == rule: # Точное совпадение
			return true
	
	return false
