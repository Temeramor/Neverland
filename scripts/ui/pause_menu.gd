extends Control
class_name PauseMenu

signal opened
signal closed
signal quit_to_menu_requested

const COLOR_BG: Color = Color("#172321")
const COLOR_PANEL: Color = Color("#263735")
const COLOR_GOLD: Color = Color("#D9A441")
const COLOR_TEXT: Color = Color("#E8D7B3")
const COLOR_MUTED: Color = Color("#B8B39A")

var _voxel_world: Node
var _main_panel: PanelContainer
var _settings_panel: PanelContainer
var _settings_scroll: ScrollContainer
var _detail_option: OptionButton
var _distance_slider: HSlider
var _distance_value_label: Label
var _distance_bands_label: Label
var _mouse_mode_before_pause: int = Input.MOUSE_MODE_VISIBLE


func configure(voxel_world: Node) -> void:
    _voxel_world = voxel_world


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP
    _build_ui()
    visible = false
    get_viewport().size_changed.connect(_fit_to_viewport)
    _fit_to_viewport()


func open_pause() -> void:
    if visible:
        return
    _show_main_page()
    _mouse_mode_before_pause = Input.mouse_mode
    visible = true
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().paused = true
    opened.emit()


func close_pause() -> void:
    if not visible:
        return
    visible = false
    get_tree().paused = false
    if OS.has_feature("android"):
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    else:
        Input.mouse_mode = _mouse_mode_before_pause
    closed.emit()


func _input(event: InputEvent) -> void:
    if not visible:
        return
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
        if _settings_panel.visible:
            _show_main_page()
        else:
            close_pause()
        get_viewport().set_input_as_handled()


func _build_ui() -> void:
    var pixel_font := load("res://assets/ui/pixel_ui.fnt") as Font
    var pause_theme := Theme.new()
    pause_theme.default_font = pixel_font if pixel_font != null else ThemeDB.fallback_font
    pause_theme.default_font_size = 15
    theme = pause_theme

    var shade := ColorRect.new()
    shade.name = "PauseShade"
    shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    shade.color = Color(0.012, 0.022, 0.020, 0.84)
    shade.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(shade)

    var center := CenterContainer.new()
    center.name = "PanelCenter"
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(center)

    _main_panel = _make_panel("PausePanel")
    center.add_child(_main_panel)
    var main_stack := VBoxContainer.new()
    main_stack.add_theme_constant_override("separation", 12)
    _main_panel.add_child(main_stack)

    var title := Label.new()
    title.text = "ПАУЗА"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 26)
    title.add_theme_color_override("font_color", COLOR_GOLD)
    main_stack.add_child(title)

    var resume_button := _make_button("Продолжить")
    resume_button.pressed.connect(close_pause)
    main_stack.add_child(resume_button)

    var settings_button := _make_button("Настройки")
    settings_button.pressed.connect(_show_settings_page)
    main_stack.add_child(settings_button)

    var quit_button := _make_button("Выйти в меню")
    quit_button.pressed.connect(_quit_to_menu)
    main_stack.add_child(quit_button)

    _settings_panel = _make_panel("LODSettingsPanel")
    center.add_child(_settings_panel)

    var settings_stack := VBoxContainer.new()
    settings_stack.add_theme_constant_override("separation", 8)
    _settings_panel.add_child(settings_stack)

    var settings_title := Label.new()
    settings_title.text = "НАСТРОЙКИ ДЕТАЛИЗАЦИИ"
    settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    settings_title.add_theme_font_size_override("font_size", 19)
    settings_title.add_theme_color_override("font_color", COLOR_GOLD)
    settings_stack.add_child(settings_title)

    var detail_heading := _make_label("Уровень детализации", true)
    settings_stack.add_child(detail_heading)

    var detail_description := _make_label(
        "Увеличивает размер ячеек сетки на дальних уровнях LOD. Это снижает число мелких полигонов вдали.",
        false
    )
    detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    settings_stack.add_child(detail_description)

    _detail_option = OptionButton.new()
    _detail_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _detail_option.add_item("Обычный: LOD1 ×2, LOD2 ×4", 0)
    _detail_option.add_item("Крупнее: LOD1 ×4, LOD2 ×8", 1)
    _detail_option.add_item("Очень крупно: LOD1 ×8, LOD2 ×16", 2)
    _detail_option.add_item("Максимум: LOD1 ×16, LOD2 ×32", 3)
    _detail_option.select(clampi(GameSettings.lod_detail_bias, 0, 3))
    _detail_option.item_selected.connect(_on_detail_level_changed)
    settings_stack.add_child(_detail_option)

    var distance_heading := _make_label("Дистанция детализации", true)
    settings_stack.add_child(distance_heading)

    var distance_description := _make_label(
        "LOD0 задаёт первую границу. Все следующие границы автоматически удваиваются.",
        false
    )
    distance_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    settings_stack.add_child(distance_description)

    var distance_row := HBoxContainer.new()
    distance_row.add_theme_constant_override("separation", 8)
    settings_stack.add_child(distance_row)

    _distance_slider = HSlider.new()
    _distance_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _distance_slider.min_value = 32.0
    _distance_slider.max_value = 256.0
    _distance_slider.step = 16.0
    _distance_slider.value = clampf(GameSettings.lod0_distance_m, 32.0, 256.0)
    _distance_slider.value_changed.connect(_on_distance_changed)
    _distance_slider.drag_ended.connect(_on_distance_drag_ended)
    _distance_slider.focus_exited.connect(_save_lod_settings)
    distance_row.add_child(_distance_slider)

    _distance_value_label = _make_label("", true)
    _distance_value_label.custom_minimum_size = Vector2(62.0, 0.0)
    _distance_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    distance_row.add_child(_distance_value_label)

    _distance_bands_label = _make_label("", false)
    _distance_bands_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _distance_bands_label.custom_minimum_size = Vector2(0.0, 84.0)
    settings_stack.add_child(_distance_bands_label)

    var hint := _make_label(
        "Настройки применяются сразу. После закрытия паузы чанки перестроятся с новым шагом сетки.",
        false
    )
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    settings_stack.add_child(hint)

    var settings_buttons := HBoxContainer.new()
    settings_buttons.add_theme_constant_override("separation", 8)
    settings_stack.add_child(settings_buttons)

    var back_button := _make_button("Назад")
    back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    back_button.pressed.connect(_show_main_page)
    settings_buttons.add_child(back_button)

    var done_button := _make_button("Готово")
    done_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    done_button.pressed.connect(_show_main_page)
    settings_buttons.add_child(done_button)

    _refresh_distance_labels()
    _show_main_page()


func _make_panel(panel_name: String) -> PanelContainer:
    var panel := PanelContainer.new()
    panel.name = panel_name
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    var style := StyleBoxFlat.new()
    style.bg_color = COLOR_PANEL
    style.border_color = COLOR_GOLD
    style.set_border_width_all(2)
    style.set_corner_radius_all(0)
    style.content_margin_left = 18.0
    style.content_margin_right = 18.0
    style.content_margin_top = 16.0
    style.content_margin_bottom = 16.0
    panel.add_theme_stylebox_override("panel", style)
    return panel


func _make_label(text_value: String, highlighted: bool) -> Label:
    var label := Label.new()
    label.text = text_value
    label.add_theme_font_size_override("font_size", 14 if highlighted else 12)
    label.add_theme_color_override("font_color", COLOR_GOLD if highlighted else COLOR_MUTED)
    return label


func _make_button(caption: String) -> Button:
    var button := Button.new()
    button.text = caption
    button.custom_minimum_size = Vector2(0.0, 46.0)
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.focus_mode = Control.FOCUS_NONE
    button.add_theme_color_override("font_color", COLOR_TEXT)
    button.add_theme_color_override("font_hover_color", COLOR_GOLD)
    button.add_theme_color_override("font_pressed_color", COLOR_GOLD)
    var normal := StyleBoxFlat.new()
    normal.bg_color = COLOR_BG
    normal.border_color = Color("#6D7554")
    normal.set_border_width_all(1)
    normal.set_corner_radius_all(0)
    button.add_theme_stylebox_override("normal", normal)
    var hover := normal.duplicate() as StyleBoxFlat
    hover.bg_color = Color("#354A43")
    hover.border_color = COLOR_GOLD
    hover.set_border_width_all(2)
    button.add_theme_stylebox_override("hover", hover)
    button.add_theme_stylebox_override("pressed", hover)
    return button


func _fit_to_viewport() -> void:
    if _main_panel == null or _settings_panel == null:
        return
    var view_size: Vector2 = get_viewport().get_visible_rect().size
    var panel_width: float = minf(560.0, maxf(250.0, view_size.x - 24.0))
    var panel_height: float = minf(680.0, maxf(300.0, view_size.y - 24.0))
    _main_panel.custom_minimum_size = Vector2(minf(panel_width, 430.0), 0.0)
    _settings_panel.custom_minimum_size = Vector2(panel_width, panel_height)


func _show_main_page() -> void:
    _main_panel.visible = true
    _settings_panel.visible = false


func _show_settings_page() -> void:
    _detail_option.select(clampi(GameSettings.lod_detail_bias, 0, 3))
    _distance_slider.set_value_no_signal(GameSettings.lod0_distance_m)
    _refresh_distance_labels()
    _main_panel.visible = false
    _settings_panel.visible = true


func _on_detail_level_changed(index: int) -> void:
    _apply_lod_settings(index, _distance_slider.value, true)


func _on_distance_changed(value: float) -> void:
    _refresh_distance_labels(value)
    _apply_lod_settings(_detail_option.get_selected_id(), value, false)


func _on_distance_drag_ended(value_changed: bool) -> void:
    if value_changed:
        _save_lod_settings()


func _save_lod_settings() -> void:
    GameSettings.update_lod_settings(
        _detail_option.get_selected_id(),
        _distance_slider.value,
        true
    )


func _apply_lod_settings(detail_bias: int, base_distance: float, persist: bool) -> void:
    GameSettings.update_lod_settings(detail_bias, base_distance, persist)
    if _voxel_world != null and is_instance_valid(_voxel_world):
        _voxel_world.call("set_lod_settings", detail_bias, base_distance)
    _refresh_distance_labels(base_distance)


func _refresh_distance_labels(base_distance: float = -1.0) -> void:
    if _distance_slider == null or _distance_value_label == null or _distance_bands_label == null:
        return
    var base: float = _distance_slider.value if base_distance < 0.0 else base_distance
    _distance_value_label.text = "%d м" % int(roundi(base))
    var bands: Array[String] = []
    var start_distance: int = 0
    for lod_index in range(6):
        var boundary: int = int(roundi(base * float(1 << lod_index)))
        bands.append("LOD%d: %d–%d м" % [lod_index, start_distance, boundary])
        start_distance = boundary
    bands.append("LOD6: от %d м" % start_distance)
    _distance_bands_label.text = "   ".join(bands)


func _quit_to_menu() -> void:
    visible = false
    get_tree().paused = false
    quit_to_menu_requested.emit()
