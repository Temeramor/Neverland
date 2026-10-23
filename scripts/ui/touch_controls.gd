extends Control
class_name TouchControls

signal movement_changed(value: Vector2)
signal look_dragged(delta: Vector2)
signal flight_toggle_requested

@export var joystick_radius: float = 82.0
@export var dead_zone: float = 10.0
@export var look_sensitivity_multiplier: float = 1.0

var _move_touch_id: int = -1
var _look_touch_id: int = -1
var _move_origin: Vector2 = Vector2.ZERO
var _move_current: Vector2 = Vector2.ZERO
var _look_active: bool = false
var _last_right_tap_msec: int = -10000
@export var double_tap_window_ms: int = 380


func _input(event: InputEvent) -> void:
    var viewport_size: Vector2 = get_viewport().get_visible_rect().size

    if event is InputEventScreenTouch:
        if event.pressed:
            # Reserve the top strip for interface buttons before touch movement or camera look.
            if event.position.y <= 88.0:
                return
            # When the profiler is expanded, do not start the movement stick or camera
            # look through the panel. Existing touch gestures remain unchanged elsewhere.
            var world_controller := get_parent().get_parent()
            if world_controller != null and bool(world_controller.get("_voxen_debug_visible")):
                var viewport_width: float = get_viewport().get_visible_rect().size.x
                var panel_width: float = maxf(240.0, minf(790.0, viewport_width - 28.0))
                if event.position.x <= 14.0 + panel_width and event.position.y <= 242.0:
                    return
            if event.position.x < viewport_size.x * 0.5 and _move_touch_id == -1:
                _move_touch_id = event.index
                _move_origin = event.position
                _move_current = event.position
                movement_changed.emit(Vector2.ZERO)
                queue_redraw()
            elif event.position.x >= viewport_size.x * 0.5 and _look_touch_id == -1:
                var now_msec: int = Time.get_ticks_msec()
                if now_msec - _last_right_tap_msec <= double_tap_window_ms:
                    _last_right_tap_msec = -10000
                    flight_toggle_requested.emit()
                else:
                    _last_right_tap_msec = now_msec
                _look_touch_id = event.index
                _look_active = true
        else:
            if event.index == _move_touch_id:
                _move_touch_id = -1
                movement_changed.emit(Vector2.ZERO)
                queue_redraw()
            if event.index == _look_touch_id:
                _look_touch_id = -1
                _look_active = false

    elif event is InputEventScreenDrag:
        if event.index == _move_touch_id:
            _move_current = event.position
            var offset: Vector2 = _move_current - _move_origin
            if offset.length() < dead_zone:
                movement_changed.emit(Vector2.ZERO)
            else:
                movement_changed.emit((offset / joystick_radius).limit_length(1.0))
            queue_redraw()
        elif event.index == _look_touch_id and _look_active:
            look_dragged.emit(event.relative * look_sensitivity_multiplier)


func _draw() -> void:
    if _move_touch_id == -1:
        return
    draw_circle(_move_origin, joystick_radius, Color(0.08, 0.10, 0.09, 0.22))
    draw_arc(_move_origin, joystick_radius, 0.0, TAU, 48, Color(0.88, 0.94, 0.87, 0.55), 2.0, true)
    var offset: Vector2 = (_move_current - _move_origin).limit_length(joystick_radius)
    var knob_position: Vector2 = _move_origin + offset
    draw_circle(knob_position, joystick_radius * 0.32, Color(0.86, 0.92, 0.82, 0.48))
    draw_arc(knob_position, joystick_radius * 0.32, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.7), 1.5, true)
