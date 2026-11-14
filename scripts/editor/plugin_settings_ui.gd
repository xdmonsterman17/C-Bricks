extends RefCounted
## The rows for one plugin's settings (target.cfg [setting.*]): a label, an editor by type, where the
## value comes from, and a reset. Used by Project Settings ("project": this project's own values over
## the global ones) and Manage plugins ("global": the editor's, for every project).
## build() fills a container and returns the state; apply() writes what was touched or reset.


## A value shown in a row's tag.
static func _tag(origin: String) -> String:
	return {"project": "set in this project", "global": "global value", "default": "default"}.get(origin, origin)


## Adds the rows for `plugin`'s settings to `parent`. `scope`: "global" or "project" (with `dir`).
static func build(parent: Control, plugin: Dictionary, scope: String, dir := "") -> Dictionary:
	var id := str(plugin.id)
	var own := TargetPlugins.set_values(id, scope, dir)
	var glob := TargetPlugins.set_values(id, "global")
	var state := {"plugin": id, "scope": scope, "dir": dir, "rows": {}}
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override(&"h_separation", 10)
	grid.add_theme_constant_override(&"v_separation", 6)
	parent.add_child(grid)
	for st: Dictionary in Array(plugin.settings):
		var key := str(st.key)
		# what the value is without this scope's own: the global one (project scope) or the default
		var inherited = TargetPlugins.coerce(st, glob[key]) if scope == "project" and glob.has(key) else st.default
		var row := {"touched": false, "clear": false, "inherited": inherited, "value": TargetPlugins.coerce(st, own[key]) if own.has(key) else inherited}
		state.rows[key] = row
		var label := Label.new()
		label.text = str(st.label)
		label.tooltip_text = str(st.tooltip)
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(label)
		var tag := Label.new()
		tag.modulate.a = 0.6
		var reset := Button.new()
		reset.text = "Reset"
		reset.flat = true
		var refresh := func() -> void:
			var origin := "project" if scope == "project" else "global"
			if row.clear or not own.has(key) and not row.touched:
				origin = "global" if scope == "project" and glob.has(key) else "default"
			tag.text = _tag(origin)
			reset.visible = origin == scope
		var editor := _editor(st, row.value)
		editor.node.tooltip_text = str(st.tooltip)
		editor.node.custom_minimum_size.x = 220
		var changed := func(v) -> void:
			row.value = TargetPlugins.coerce(st, v)
			row.touched = true
			row.clear = false
			refresh.call()
		editor.connect_changed.call(changed)
		reset.pressed.connect(func() -> void:
			row.clear = true
			row.touched = false
			row.value = row.inherited
			editor.set_value.call(row.inherited)
			refresh.call())
		reset.tooltip_text = "Back to %s" % ("the global value" if scope == "project" else "the default")
		grid.add_child(editor.node)
		grid.add_child(tag)
		grid.add_child(reset)
		refresh.call()
	return state


## Writes the touched values and clears the reset ones (an untouched one stays as it was).
static func apply(state: Dictionary) -> void:
	for key in state.rows:
		var row: Dictionary = state.rows[key]
		if row.clear:
			TargetPlugins.set_value(str(state.plugin), str(state.scope), str(key), null, str(state.dir))
		elif row.touched:
			TargetPlugins.set_value(str(state.plugin), str(state.scope), str(key), row.value, str(state.dir))


## {"node": the control, "connect_changed": Callable(Callable), "set_value": Callable(value)}.
static func _editor(st: Dictionary, value) -> Dictionary:
	match str(st.type):
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(value)
			return {"node": cb, "connect_changed": func(f: Callable) -> void: cb.toggled.connect(f),
				"set_value": func(v) -> void: cb.set_pressed_no_signal(bool(v))}
		"int":
			var sp := SpinBox.new()
			sp.min_value = -2147483648
			sp.max_value = 2147483647
			sp.value = int(value)
			return {"node": sp, "connect_changed": func(f: Callable) -> void: sp.value_changed.connect(f),
				"set_value": func(v) -> void: sp.set_value_no_signal(int(v))}
		"choice":
			var ob := OptionButton.new()
			for c in st.choices:
				ob.add_item(str(c))
			ob.select(maxi(0, Array(st.choices).find(str(value))))
			return {"node": ob, "connect_changed": func(f: Callable) -> void: ob.item_selected.connect(func(i: int) -> void: f.call(str(st.choices[i]))),
				"set_value": func(v) -> void: ob.select(maxi(0, Array(st.choices).find(str(v))))}
	var le := LineEdit.new()
	le.text = str(value)
	return {"node": le, "connect_changed": func(f: Callable) -> void: le.text_changed.connect(f),
		"set_value": func(v) -> void: le.text = str(v)}
