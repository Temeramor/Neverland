extends CharacterBody3D
class_name PlayerController

signal flight_mode_changed(enabled: bool)

@export var walk_speed: float = 7.0
@export var acceleration: float = 22.0
@export var gravity: float = 24.0
@export var look_sensitivity: float = 0.003
@export var flight_speed_multiplier: float = 10.0
@export_range(82.0, 120.0, 1.0) var flight_fov: float = 100.0
@export var base_camera_fov: float = 82.0
@export var double_tap_window_ms: int = 380

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D

var touch_move: Vector2 = Vector2.ZERO
var is_flying: bool = false
var _mouse_look_active: bool = false
var mouse_capture_paused: bool = false
var _camera_yaw: float = 0.0
var _camera_pitch: float = 0.0
var _last_space_tap_msec: int = -10000


func _ready() -> void:
    camera_pivot.rotation = Vector3(_camera_pitch, _camera_yaw, 0.0)
    camera.fov = base_camera_fov


func set_touch_move(value: Vector2) -> void:
    touch_move = value.limit_length(1.0)


func apply_look_delta(delta: Vector2) -> void:
    _rotate_camera(delta)


func reset_camera() -> void:
    _camera_yaw = 0.0
    _camera_pitch = 0.0
    camera_pivot.rotation = Vector3(_camera_pitch, _camera_yaw, 0.0)
    if is_flying:
        is_flying = false
        flight_mode_changed.emit(false)
    camera.fov = base_camera_fov


func toggle_flight_mode() -> void:
    is_flying = not is_flying
    # Avoid carrying a large vertical impulse across the switch. While flight is
    # enabled movement follows the complete view vector, including camera pitch.
    velocity.y = 0.0
    camera.fov = flight_fov if is_flying else base_camera_fov
    flight_mode_changed.emit(is_flying)


func _physics_process(delta: float) -> void:
    if mouse_capture_paused:
        velocity = Vector3.ZERO
        move_and_slide()
        return

    var input_vector := touch_move

    # Keyboard fallback for testing in the editor (WASD or arrows).
    if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
        input_vector.x -= 1.0
    if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
        input_vector.x += 1.0
    if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
        input_vector.y -= 1.0
    if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
        input_vector.y += 1.0
    input_vector = input_vector.limit_length(1.0)

    if is_flying:
        var camera_forward: Vector3 = -camera.global_transform.basis.z.normalized()
        var camera_right: Vector3 = camera.global_transform.basis.x.normalized()
        var flight_direction: Vector3 = camera_right * input_vector.x + camera_forward * -input_vector.y
        if flight_direction.length_squared() > 0.0001:
            flight_direction = flight_direction.normalized()
        var flight_speed: float = walk_speed * flight_speed_multiplier
        velocity = velocity.move_toward(flight_direction * flight_speed, acceleration * flight_speed_multiplier * delta)
        move_and_slide()
        return

    # Walking follows camera yaw, while remaining locked to the ground plane.
    var move_direction := Vector3(input_vector.x, 0.0, input_vector.y)
    move_direction = move_direction.rotated(Vector3.UP, _camera_yaw)
    if move_direction.length_squared() > 0.0001:
        move_direction = move_direction.normalized()

    var target_x: float = move_direction.x * walk_speed
    var target_z: float = move_direction.z * walk_speed
    velocity.x = move_toward(velocity.x, target_x, acceleration * delta)
    velocity.z = move_toward(velocity.z, target_z, acceleration * delta)

    if not is_on_floor():
        velocity.y -= gravity * delta
    elif velocity.y < 0.0:
        velocity.y = -0.5

    move_and_slide()

    if move_direction.length_squared() > 0.02:
        var facing := Vector3(move_direction.x, 0.0, move_direction.z)
        if facing.length_squared() > 0.001:
            var target_angle := atan2(-facing.x, -facing.z)
            $BodyVisual.rotation.y = lerp_angle($BodyVisual.rotation.y, target_angle, minf(9.0 * delta, 1.0))


func _input(event: InputEvent) -> void:
    if mouse_capture_paused:
        return

    # Double-space toggles flight on desktop; touch controls emit the same toggle
    # after a double tap on the right half of the screen.
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == KEY_SPACE:
            var now_msec: int = Time.get_ticks_msec()
            if now_msec - _last_space_tap_msec <= double_tap_window_ms:
                _last_space_tap_msec = -10000
                toggle_flight_mode()
            else:
                _last_space_tap_msec = now_msec
            return
        
func _unhandled_input(event: InputEvent) -> void:
    if mouse_capture_paused:
        return

    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        _mouse_look_active = true
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        _rotate_camera(event.relative)


func _rotate_camera(delta: Vector2) -> void:
    _camera_yaw -= delta.x * look_sensitivity
    _camera_pitch -= delta.y * look_sensitivity
    _camera_pitch = clampf(_camera_pitch, -1.45, 1.45)
    camera_pivot.rotation = Vector3(_camera_pitch, _camera_yaw, 0.0)
