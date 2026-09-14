extends Node3D
## Application root: owns the UI layers, the world lifecycle and global input.
##
## Command line:
##   --test-run=<seconds>   boot straight into the world, run headless for N
##                          seconds, print a JSON smoke-test report and quit.
##   --bench=<standard|endurance>  boot into the world and run a benchmark.
##   --seed=<int>           override the world seed.

const SMOKE_REPORT_PATH: String = "user://redline_smoke.json"

var world: WorldManager = null
var ui_layer: CanvasLayer
var postfx_layer: CanvasLayer = null
var touch: TouchInput
var game_hud: GameHUD
var perf_hud: PerfHUD
var bench_overlay: BenchmarkOverlay
var pause_menu: PauseMenu
var main_menu: MainMenu

var _test_seconds: float = -1.0
var _test_elapsed: float = 0.0
var _auto_bench: int = -1
var _errors: Array[String] = []
var _started: bool = false
var _test_autopilot: bool = false
var _test_travel: bool = false
var _test_sweep: bool = false
var _sweep_timer: float = 0.0
var _sweep_step: int = 0
var _shot_times: Array[float] = []
var _shot_dir: String = "user://shots"
var _shot_index: int = 0
var _start_radius: float = -1.0
var _force_quality: int = -1
var _start_time: float = -1.0
var _selftest: bool = false
var _mesh_gallery: bool = false
var _godmode: bool = false
var _show_menu: bool = false
var _safety_off: bool = false


func _ready() -> void:
	name = "Main"
	randomize()
	_parse_cli()

	# Grade layer sits between the 3D viewport and the HUD: vignette and grain
	# belong to the image, not to the interface.
	_build_postfx()

	ui_layer = CanvasLayer.new()
	ui_layer.name = "UI"
	ui_layer.layer = 10
	add_child(ui_layer)

	touch = TouchInput.new()
	ui_layer.add_child(touch)
	touch.look_sensitivity = float(GameConfig.settings.get("look_sensitivity", 1.0))
	touch.pause_pressed.connect(_toggle_pause)
	touch.hud_pressed.connect(func() -> void: perf_hud.cycle())
	touch.stress_pressed.connect(func(d: int) -> void: StressDirector.step(d))

	game_hud = GameHUD.new()
	ui_layer.add_child(game_hud)
	game_hud.visible = false

	perf_hud = PerfHUD.new()
	ui_layer.add_child(perf_hud)

	bench_overlay = BenchmarkOverlay.new()
	ui_layer.add_child(bench_overlay)
	bench_overlay.closed.connect(_on_bench_closed)
	bench_overlay.rerun_requested.connect(_start_benchmark)

	pause_menu = PauseMenu.new()
	ui_layer.add_child(pause_menu)
	pause_menu.resume_requested.connect(_resume)
	pause_menu.respawn_requested.connect(_respawn)
	pause_menu.quit_requested.connect(_quit)
	pause_menu.benchmark_requested.connect(_start_benchmark)

	main_menu = MainMenu.new()
	ui_layer.add_child(main_menu)
	main_menu.play_requested.connect(_start_game)
	main_menu.benchmark_requested.connect(_start_from_menu)
	main_menu.settings_requested.connect(_open_settings_from_menu)
	main_menu.quit_requested.connect(_quit)

	EventBus.safety_throttle.connect(_on_safety)
	if _safety_off:
		PerformanceMonitor.watchdog_enabled = false
		push_warning("REDLINE: low-FPS safety watchdog disabled by --safety-off")
	EventBus.benchmark_finished.connect(_on_benchmark_finished)
	EventBus.benchmark_aborted.connect(_on_benchmark_aborted)
	get_tree().auto_accept_quit = true

	if _selftest:
		call_deferred("_run_selftest")
		return

	if _mesh_gallery:
		main_menu.visible = false
		perf_hud.set_mode(PerfHUD.Mode.OFF)
		MaterialLib.refresh_for_preset(AdaptiveQualityManager.preset)
		MeshLib.reset()
		MeshLib.get_instance()
		var gallery := MeshGallery.new()
		add_child(gallery)
		gallery.build()
		_started = true
		return

	if (_test_seconds > 0.0 or _auto_bench >= 0) and not _show_menu:
		_start_game()
		if _auto_bench >= 0:
			await get_tree().create_timer(2.0).timeout
			_start_benchmark(_auto_bench)


## Full-screen grade. A transparent quad in its own CanvasLayer rather than a
## screen-space post-process, because Godot's mobile renderer cannot read the
## screen buffer.
func _build_postfx() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var shader: Shader = load("res://shaders/postfx.gdshader") as Shader
	if shader == null:
		return
	postfx_layer = CanvasLayer.new()
	postfx_layer.name = "PostFX"
	postfx_layer.layer = 5
	add_child(postfx_layer)
	var rect := ColorRect.new()
	rect.name = "Grade"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	rect.material = mat
	postfx_layer.add_child(rect)


## Static geometry/determinism/safety checks. No world, no display.
func _run_selftest() -> void:
	MaterialLib.refresh_for_preset(AdaptiveQualityManager.preset)
	MeshLib.reset()
	MeshLib.get_instance()
	var results: Dictionary = SelfTest.run_all(GameConfig.world_seed)
	print("REDLINE_SELFTEST_BEGIN")
	print(JSON.stringify(results, "  "))
	print("REDLINE_SELFTEST_END")
	get_tree().quit(0 if bool(results["ok"]) else 1)


func _parse_cli() -> void:
	for arg: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--test-run="):
			_test_seconds = maxf(1.0, float(arg.split("=")[1]))
		elif arg.begins_with("--bench="):
			_auto_bench = (BenchmarkManager.Mode.ENDURANCE
				if arg.split("=")[1] == "endurance" else BenchmarkManager.Mode.STANDARD)
		elif arg.begins_with("--seed="):
			GameConfig.world_seed = int(arg.split("=")[1])
		elif arg.begins_with("--stress="):
			StressDirector.set_level(int(arg.split("=")[1]), false)
		elif arg == "--test-autopilot":
			_test_autopilot = true
		elif arg == "--test-travel":
			_test_autopilot = true
			_test_travel = true
		elif arg == "--test-sweep":
			_test_sweep = true
		elif arg.begins_with("--shots="):
			# Comma separated seconds at which to capture the framebuffer.
			for t: String in arg.split("=")[1].split(","):
				_shot_times.append(float(t))
			_shot_times.sort()
		elif arg.begins_with("--shot-dir="):
			_shot_dir = arg.split("=", true, 1)[1]
		elif arg.begins_with("--start-radius="):
			_start_radius = float(arg.split("=")[1])
		elif arg.begins_with("--hud="):
			GameConfig.settings["hud_mode"] = int(arg.split("=")[1])
		elif arg == "--force-touch":
			GameConfig.settings["touch_controls"] = 1
		elif arg.begins_with("--quality="):
			_force_quality = int(arg.split("=")[1])
		elif arg.begins_with("--time-of-day="):
			_start_time = float(arg.split("=")[1])
		elif arg == "--selftest":
			_selftest = true
		elif arg == "--mesh-gallery":
			_mesh_gallery = true
		elif arg == "--godmode":
			_godmode = true
		elif arg == "--show-menu":
			_show_menu = true
		elif arg == "--safety-off":
			# Development only, for capturing the interface under a software
			# renderer where the low-FPS watchdog would otherwise fire
			# immediately. Never set in a shipped build.
			_safety_off = true


# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------
func _start_game() -> void:
	if _started:
		return
	_started = true
	main_menu.visible = false
	game_hud.visible = true

	world = WorldManager.new()
	world.name = "World"
	add_child(world)
	world.build(touch)

	perf_hud.bind_world(world)
	pause_menu.bind_world(world)
	game_hud.bind(world.player, world, touch, perf_hud)

	if _force_quality >= 0:
		AdaptiveQualityManager.apply_preset(_force_quality, false)
	if _start_radius > 0.0:
		world.bench_teleport(_start_radius)
	if _start_time >= 0.0:
		world.day_night.set_time(_start_time)
		world.day_night.paused = true

	GameState.reset_run()
	GameState.set_phase(GameState.Phase.PLAYING)
	GameState.set_invulnerable(_godmode)
	world.player.capture_mouse(true)
	if _test_autopilot:
		world.player.set_autopilot(true)
		world.player.autopilot_speed = 14.0
		world.player.autopilot_outward = _test_travel
	EventBus.notify("REDLINE ONLINE", 3.0)


func _resume() -> void:
	pause_menu.close()
	get_tree().paused = false
	if GameState.phase == GameState.Phase.PAUSED:
		GameState.set_phase(GameState.Phase.PLAYING)
	if world != null and world.player != null:
		world.player.capture_mouse(true)


func _pause() -> void:
	if not _started:
		return
	get_tree().paused = true
	GameState.set_phase(GameState.Phase.PAUSED)
	pause_menu.open()
	if world != null and world.player != null:
		world.player.capture_mouse(false)


func _toggle_pause() -> void:
	if not _started:
		return
	if get_tree().paused:
		_resume()
	else:
		_pause()


func _respawn() -> void:
	if world == null:
		return
	pause_menu.close()
	get_tree().paused = false
	world.respawn()
	world.player.capture_mouse(true)


func _quit() -> void:
	get_tree().quit()


func _open_settings_from_menu() -> void:
	pause_menu.bind_world(world)
	pause_menu.open()


func _start_from_menu(mode: int) -> void:
	_start_game()
	await get_tree().create_timer(1.2).timeout
	_start_benchmark(mode)


func _start_benchmark(mode: int) -> void:
	if not _started:
		_start_game()
	pause_menu.close()
	get_tree().paused = false
	if world != null and world.player != null:
		world.player.capture_mouse(false)
	if not BenchmarkManager.start(mode):
		EventBus.notify("Could not start benchmark", 3.0)


func _on_bench_closed() -> void:
	if world != null and world.player != null:
		world.player.capture_mouse(true)


func _on_safety(reason: String) -> void:
	_errors.append("safety throttle: " + reason)


## In headless CLI mode the results are printed and the process exits, so CI
## can diff a benchmark run without a display.
func _on_benchmark_finished(results: Dictionary) -> void:
	if _auto_bench < 0:
		return
	print("REDLINE_BENCH_BEGIN")
	print(JSON.stringify(results, "  "))
	print("REDLINE_BENCH_END")
	# Stay up if screenshots are still pending, so the results screen can be
	# captured; the --test-run timer ends the process instead.
	if _shot_index < _shot_times.size():
		return
	get_tree().quit(0)


func _on_benchmark_aborted(reason: String) -> void:
	if _auto_bench < 0:
		return
	printerr("REDLINE_BENCH_ABORTED: " + reason)
	get_tree().quit(2)


# -----------------------------------------------------------------------------
# Global input
# -----------------------------------------------------------------------------
func _unhandled_input(_event: InputEvent) -> void:
	if Input.is_action_just_pressed("pause"):
		_toggle_pause()
	if Input.is_action_just_pressed("toggle_hud"):
		perf_hud.toggle()
	if Input.is_action_just_pressed("cycle_hud"):
		perf_hud.cycle()
	if Input.is_action_just_pressed("toggle_touch"):
		touch.toggle()
	if Input.is_action_just_pressed("stress_up"):
		StressDirector.step(1)
	if Input.is_action_just_pressed("stress_down"):
		StressDirector.step(-1)
	if Input.is_action_just_pressed("toggle_stress_auto"):
		StressDirector.set_auto(not StressDirector.auto_mode)
	if Input.is_action_just_pressed("run_benchmark"):
		_start_benchmark(BenchmarkManager.Mode.STANDARD)
	if Input.is_action_just_pressed("run_endurance"):
		_start_benchmark(BenchmarkManager.Mode.ENDURANCE)
	if Input.is_action_just_pressed("free_mouse") and world != null:
		world.player.capture_mouse(false)


func _process(delta: float) -> void:
	if GameState.phase == GameState.Phase.DEAD and _started and not get_tree().paused:
		_handle_death()
	if _test_sweep:
		_run_sweep(delta)
	if _shot_index < _shot_times.size() and _test_elapsed >= _shot_times[_shot_index]:
		var label: String = "shot_%02d_t%.0f" % [_shot_index, _shot_times[_shot_index]]
		_shot_index += 1
		_capture(label)
	if _test_seconds > 0.0:
		_test_elapsed += delta
		if _test_elapsed >= _test_seconds:
			_finish_test_run()


## Cycles every quality preset and every stress level while the world is live.
## This is where regressions in material rebuilds, cache invalidation and
## budget re-application show up.
func _run_sweep(delta: float) -> void:
	_sweep_timer += delta
	if _sweep_timer < 2.5:
		return
	_sweep_timer = 0.0
	var presets: int = AdaptiveQualityManager.PRESET_NAMES.size()
	var levels: int = StressDirector.LEVEL_NAMES.size()
	if _sweep_step < presets:
		AdaptiveQualityManager.apply_preset(_sweep_step, false)
	elif _sweep_step < presets + levels:
		StressDirector.set_level(_sweep_step - presets, false)
	elif _sweep_step == presets + levels:
		GameConfig.settings["high_memory_mode"] = true
		StressDirector._recompute()
	elif _sweep_step == presets + levels + 1:
		StressDirector.set_auto(true)
	else:
		_sweep_step = -1
	_sweep_step += 1


## Saves the actual framebuffer. Used to verify the render on a machine with
## no display (Xvfb plus Mesa's lavapipe software Vulkan driver).
func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var tex: ViewportTexture = get_viewport().get_texture()
	if tex == null:
		printerr("capture failed: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		printerr("capture failed: no image")
		return
	DirAccess.make_dir_recursive_absolute(_shot_dir)
	var path: String = "%s/%s.png" % [_shot_dir, label]
	var err: int = img.save_png(path)
	if err != OK:
		printerr("capture failed (%d): %s" % [err, path])
		return
	print("REDLINE_SHOT %s" % ProjectSettings.globalize_path(path))


var _death_timer: float = 0.0


func _handle_death() -> void:
	_death_timer += get_process_delta_time()
	if _death_timer > 3.0:
		_death_timer = 0.0
		world.respawn()


# -----------------------------------------------------------------------------
# Headless smoke test
# -----------------------------------------------------------------------------
func _finish_test_run() -> void:
	_test_seconds = -1.0
	var p := PerformanceMonitor
	var probe: Dictionary = world.debug_probe() if world != null else {}
	if not bool(probe.get("ray_from_above_hits", true)):
		_errors.append("no collision surface under the player")
	if bool(probe.get("ray_from_below_hits", false)):
		_errors.append("collision trimesh is inside out")
	var report: Dictionary = {
		"ok": _errors.is_empty(),
		"errors": _errors,
		"seconds": _test_elapsed,
		"frames": p.frame_ms_long.size(),
		"avg_fps": p.avg_fps,
		"display_server": DisplayServer.get_name(),
		"counters": p.counters.duplicate(),
		"world_stats": world.world_stats() if world != null else {},
		"ground_probe": world.debug_probe() if world != null else {},
		"stress": {
			"level": StressDirector.level,
			"name": StressDirector.level_name(),
			"effective": StressDirector.effective,
		},
		"quality": {
			"preset": AdaptiveQualityManager.preset_name(),
			"reason": AdaptiveQualityManager.detect_reason(),
			"render_scale": AdaptiveQualityManager.current_render_scale(),
		},
		"gamestate": GameState.summary(),
	}
	var f: FileAccess = FileAccess.open(SMOKE_REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print("REDLINE_SMOKE_BEGIN")
	print(JSON.stringify(report, "  "))
	print("REDLINE_SMOKE_END")
	get_tree().quit(0 if _errors.is_empty() else 1)
