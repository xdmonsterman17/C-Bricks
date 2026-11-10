extends RefCounted

## This machine's player profile: a username and a user ID, saved on this
## machine (user://). The ID is made once, at random, and never changes, so
## two players with the same name are still different users and a rename
## keeps it. (No logins: a modified game could still send any ID.)

const SECTION: String = "profile"
## Where it's kept. Tests point it elsewhere so they don't change yours.
static var path: String = "user://brickscript_profile.cfg"


## Keeps the profile in another file (tests: so yours stays as it is).
static func use_file(file_path: String) -> void:
	path = file_path


## {"username": String, "user_id": String}, made (and saved) the first time.
static func load_profile() -> Dictionary:
	var file: ConfigFile = ConfigFile.new()
	file.load(path)
	var username: String = clean_name(str(file.get_value(SECTION, "username", "")))
	var user_id: String = str(file.get_value(SECTION, "user_id", ""))
	if username.is_empty() or user_id.is_empty():
		if username.is_empty():
			username = clean_name(OS.get_environment("USER") if not OS.get_environment("USER").is_empty() else OS.get_environment("USERNAME"))
		if username.is_empty():
			username = "Player"
		if user_id.is_empty():
			user_id = Crypto.new().generate_random_bytes(8).hex_encode()
		file.set_value(SECTION, "username", username)
		file.set_value(SECTION, "user_id", user_id)
		file.save(path)
	return {"username": username, "user_id": user_id}


## Saves a new username (cleaned; empty is refused). Returns the one saved.
static func save_username(username: String) -> String:
	var cleaned: String = clean_name(username)
	if cleaned.is_empty():
		return str(load_profile()["username"])
	var profile: Dictionary = load_profile()
	var file: ConfigFile = ConfigFile.new()
	file.load(path)
	file.set_value(SECTION, "username", cleaned)
	file.set_value(SECTION, "user_id", profile["user_id"])
	file.save(path)
	return cleaned


## A username that is also a valid node name: no . : @ / " % and at most 24
## characters, spaces at the ends trimmed.
static func clean_name(username: String) -> String:
	var cleaned: String = username.strip_edges()
	for bad: String in [".", ":", "@", "/", "\"", "%", "\\", "\n", "\t"]:
		cleaned = cleaned.replace(bad, "")
	return cleaned.left(24).strip_edges()
