@tool
extends RefCounted
class_name GitUtils

# ЭТИ ПАПКИ ИГНОРИРУЮТСЯ ВСЕГДА (Жесткая защита от зависаний)
const HARD_IGNORE_DIRS = [".git", ".godot", ".import", "android", "ios", "build", "cmake-build-debug", "node_modules"]

# Стандартный шаблон .gitignore
const DEFAULT_TEXT = """# Godot
.godot/
.import/
export.cfg
export_presets.cfg
*.uid

# Android/Mobile
android/
ios/
*.apks
*.aab

# Temp
*.tmp
*.bak
*.log
"""

var simple_extensions = [] 
var path_rules = []

func load_gitignore(path: String = "res://.gitignore"):
	simple_extensions.clear()
	path_rules.clear()
	
	# Если файла нет, используем дефолтные правила в памяти
	if not FileAccess.file_exists(path):
		_parse_rules(DEFAULT_TEXT.split("\n"))
		return

	var f = FileAccess.open(path, FileAccess.READ)
	if f:
		var text = f.get_as_text()
		_parse_rules(text.split("\n"))

func _parse_rules(lines):
	for line in lines:
		line = line.strip_edges()
		if line == "" or line.begins_with("#"): continue
		
		# Оптимизация для расширений (*.png)
		if line.begins_with("*.") and not "/" in line:
			simple_extensions.append(line.replace("*.", ""))
		else:
			path_rules.append(line)

func is_ignored(path: String) -> bool:
	# path приходит как "res://folder/file.gd"
	var rel_path = path.replace("res://", "")
	var file_name = rel_path.get_file()
	
	# 1. Быстрая проверка UID (критично для Godot 4)
	if file_name.ends_with(".uid"): return true
	
	# 2. Проверка по расширению
	var ext = file_name.get_extension()
	if ext in simple_extensions: return true
	
	# 3. Сложные правила путей
	for rule in path_rules:
		if rule.ends_with("/"):
			if rel_path.begins_with(rule) or rel_path.begins_with(rule.trim_suffix("/")):
				return true
		elif "*" in rule:
			if rel_path.matchn(rule) or file_name.matchn(rule):
				return true
		elif rel_path == rule:
			return true
			
	return false

func has_gitignore() -> bool:
	return FileAccess.file_exists("res://.gitignore")

func create_default_gitignore():
	var f = FileAccess.open("res://.gitignore", FileAccess.WRITE)
	if f:
		f.store_string(DEFAULT_TEXT)
		f.close()
		load_gitignore()
