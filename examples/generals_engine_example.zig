// Home Programming Language - C&C Generals Engine Example
// Demonstrates using the game development framework with macOS native rendering
//
// This example integrates:
// - Game ECS (Entity Component System)
// - Game AI (Behavior trees, state machines)
// - Game pathfinding (A* algorithm)
// - Game loop (Fixed timestep with interpolation)
// - OpenGL rendering
// - OpenAL audio
// - macOS Cocoa windowing

const std = @import("std");

// Graphics packages
const gl = @import("opengl");
const al = @import("openal");
const cocoa = @import("cocoa");
const input_mod = @import("input");

// Game packages
const game = @import("game");
const game_loop = @import("game_loop");
const game_ecs = @import("game_ecs");
const game_ai = @import("game_ai");
const game_pathfinding = @import("game_pathfinding");
const game_network = @import("game_network");
const game_replay = @import("game_replay");
const game_mods = @import("game_mods");

// W3D Model loading
const w3d_loader = @import("w3d_loader");

// Window dimensions
const WINDOW_WIDTH: u32 = 1280;
const WINDOW_HEIGHT: u32 = 720;

// C&C Generals UI Colors and Layout
const UI = struct {
    // Panel colors (dark military green/gray from Generals)
    const panel_bg = [4]f32{ 0.12, 0.14, 0.12, 0.95 };
    const panel_border = [4]f32{ 0.3, 0.35, 0.3, 1.0 };
    const panel_highlight = [4]f32{ 0.4, 0.45, 0.4, 1.0 };

    // Button colors
    const button_bg = [4]f32{ 0.18, 0.22, 0.18, 1.0 };
    const button_hover = [4]f32{ 0.25, 0.30, 0.25, 1.0 };
    const button_border = [4]f32{ 0.4, 0.5, 0.4, 1.0 };

    // Resource colors
    const money_color = [3]f32{ 0.0, 0.9, 0.3 }; // Green money
    const power_positive = [3]f32{ 0.3, 0.8, 1.0 }; // Blue power
    const power_negative = [3]f32{ 1.0, 0.3, 0.3 }; // Red low power

    // Team colors (USA Blue, China Red, GLA Tan)
    const team_usa = [3]f32{ 0.2, 0.5, 1.0 };
    const team_china = [3]f32{ 1.0, 0.2, 0.2 };
    const team_gla = [3]f32{ 0.8, 0.7, 0.4 };

    // Selection
    const selection_color = [3]f32{ 0.0, 1.0, 0.0 };

    // Minimap
    const minimap_bg = [4]f32{ 0.08, 0.10, 0.08, 0.9 };
    const minimap_border = [4]f32{ 0.35, 0.4, 0.35, 1.0 };
    const minimap_viewport = [4]f32{ 1.0, 1.0, 1.0, 0.5 };

    // Layout dimensions
    const sidebar_width: f32 = 200;
    const bottom_panel_height: f32 = 140;
    const minimap_size: f32 = 180;
    const top_bar_height: f32 = 36;
};

// ============================================================================
// Game Components (for ECS)
// ============================================================================

const Position = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
    dz: f32,
};

const Health = struct {
    current: f32,
    max: f32,
};

const UnitType = enum {
    // Infantry
    ranger,
    missile_defender,
    red_guard,
    tank_hunter,
    rebel,
    rpg_trooper,
    // Vehicles
    crusader_tank,
    paladin_tank,
    battlemaster,
    overlord,
    scorpion_tank,
    marauder_tank,
    humvee,
    troop_crawler,
    technical,
    // Aircraft
    comanche,
    raptor,
    mig,
    helix,
    // Buildings
    command_center,
    barracks,
    war_factory,
    airfield,
    supply_depot,
    power_plant,
    // Generic fallback
    infantry,
    tank,
    helicopter,
    building,
};

const Faction = enum {
    usa,
    china,
    gla,

    pub fn getColor(self: Faction) [3]f32 {
        return switch (self) {
            .usa => UI.team_usa,
            .china => UI.team_china,
            .gla => UI.team_gla,
        };
    }

    pub fn getName(self: Faction) []const u8 {
        return switch (self) {
            .usa => "USA",
            .china => "China",
            .gla => "GLA",
        };
    }
};

const Unit = struct {
    unit_type: UnitType,
    team: u8,
    faction: Faction,
    attack_damage: f32,
    attack_range: f32,
    move_speed: f32,
    selected: bool,
};

const PlayerResources = struct {
    money: i32,
    power_produced: i32,
    power_consumed: i32,
    faction: Faction,
    generals_points: u8,
    generals_rank: u8,

    pub fn init(faction: Faction) PlayerResources {
        return .{
            .money = 5000, // Starting money
            .power_produced = 0,
            .power_consumed = 0,
            .faction = faction,
            .generals_points = 0,
            .generals_rank = 1,
        };
    }

    pub fn powerBalance(self: PlayerResources) i32 {
        return self.power_produced - self.power_consumed;
    }

    pub fn hasPower(self: PlayerResources) bool {
        return self.powerBalance() >= 0;
    }
};

// ============================================================================
// Game State
// ============================================================================

// Loaded W3D model with GPU-ready data
const LoadedModel = struct {
    model: *w3d_loader.W3DModel,
    scale: f32,
};

// Model cache for unit types
const UnitModelCache = struct {
    ranger: ?LoadedModel = null,
    crusader_tank: ?LoadedModel = null,
    paladin_tank: ?LoadedModel = null,
    battlemaster: ?LoadedModel = null,
    overlord: ?LoadedModel = null,
    red_guard: ?LoadedModel = null,
    technical: ?LoadedModel = null,
    scorpion: ?LoadedModel = null,
    marauder: ?LoadedModel = null,
};

const GameState = struct {
    allocator: std.mem.Allocator,
    world: game_ecs.SimpleWorld,
    pathfinder: *game_pathfinding.Grid,

    // Rendering
    running: bool,
    window: cocoa.id,
    gl_context: cocoa.id,
    input_state: input_mod.InputState,

    // W3D Model loading
    w3d: w3d_loader.W3DLoader,
    model_cache: UnitModelCache,
    models_loaded: bool,
    assets_path: []const u8,

    // Camera - 3D perspective for proper model viewing
    camera_x: f32,
    camera_y: f32,
    camera_z: f32, // Height above ground
    camera_pitch: f32, // Looking down angle
    camera_zoom: f32,

    // Game time
    total_time: f64,
    frame_count: u64,

    // Player resources
    player_resources: PlayerResources,
    enemy_resources: PlayerResources,

    // Unit positions for rendering
    unit_positions: std.ArrayList(UnitRenderData),

    // Selection state
    selected_units: std.ArrayList(usize),
    selection_box_start: ?struct { x: f32, y: f32 },
    selection_box_end: ?struct { x: f32, y: f32 },
    is_selecting: bool,

    // UI state
    hovered_button: ?u8,
    active_build_queue: std.ArrayList(UnitType),

    const UnitRenderData = struct {
        x: f32,
        y: f32,
        z: f32, // Height for 3D rendering
        unit_type: UnitType,
        team: u8,
        faction: Faction,
        health: f32,
        max_health: f32,
        selected: bool,
        entity_id: u32,
        rotation: f32, // Y-axis rotation in radians
    };

    pub fn init(allocator: std.mem.Allocator) !*GameState {
        const self = try allocator.create(GameState);
        self.* = GameState{
            .allocator = allocator,
            .world = game_ecs.SimpleWorld.init(allocator),
            .pathfinder = try game_pathfinding.Grid.init(allocator, 100, 100, .{}),
            .running = true,
            .window = null,
            .gl_context = null,
            .input_state = input_mod.InputState.init(allocator),
            .w3d = w3d_loader.W3DLoader.init(allocator),
            .model_cache = .{},
            .models_loaded = false,
            .assets_path = "/Users/chrisbreuer/Code/generals/Generals.app/Contents/Resources/assets",
            .camera_x = 0,
            .camera_y = -200, // Pull back to see scene
            .camera_z = 300, // Height for isometric-like view
            .camera_pitch = 0.7, // ~40 degrees down
            .camera_zoom = 1.0,
            .total_time = 0,
            .frame_count = 0,
            .player_resources = PlayerResources.init(.usa),
            .enemy_resources = PlayerResources.init(.china),
            .unit_positions = .{},
            .selected_units = .{},
            .selection_box_start = null,
            .selection_box_end = null,
            .is_selecting = false,
            .hovered_button = null,
            .active_build_queue = .{},
        };
        // Give player starting power
        self.player_resources.power_produced = 10;
        self.player_resources.power_consumed = 5;
        return self;
    }

    /// Load W3D models from game assets
    pub fn loadModels(self: *GameState) !void {
        if (self.models_loaded) return;

        std.debug.print("\nLoading W3D models...\n", .{});

        // Path to actual game W3D files from patch directory
        const patch_w3d_path = "/Users/chrisbreuer/Code/generals-game-patch/Patch104pZH/GameFilesEdited/Art/W3D/";
        const resources_path = "/Users/chrisbreuer/Code/generals/Generals.app/Contents/Resources/assets/models/";

        // Load building models for testing (these are actual W3D files)
        var models_loaded_count: u32 = 0;

        // Try to load barracks model (building - shows W3D parsing works)
        const barracks_paths = [_][]const u8{
            patch_w3d_path ++ "ABBarracks_D.W3D",
            resources_path ++ "ABBarracks_D.W3D",
        };
        for (barracks_paths) |path| {
            if (try self.w3d.load(path)) |model| {
                if (model.meshes.len > 0) {
                    self.model_cache.ranger = .{ .model = model, .scale = 0.02 };
                    std.debug.print("  Loaded: {s} ({d} meshes)\n", .{ path, model.meshes.len });
                    models_loaded_count += 1;
                    break;
                }
            }
        }

        // Load power plant for tanks
        const power_paths = [_][]const u8{
            patch_w3d_path ++ "ABPwrPlant_D.W3D",
            resources_path ++ "ABPwrPlant_D.W3D",
        };
        for (power_paths) |path| {
            if (try self.w3d.load(path)) |model| {
                if (model.meshes.len > 0) {
                    self.model_cache.crusader_tank = .{ .model = model, .scale = 0.02 };
                    self.model_cache.paladin_tank = .{ .model = model, .scale = 0.025 };
                    self.model_cache.battlemaster = .{ .model = model, .scale = 0.02 };
                    self.model_cache.overlord = .{ .model = model, .scale = 0.03 };
                    std.debug.print("  Loaded: {s} ({d} meshes)\n", .{ path, model.meshes.len });
                    models_loaded_count += 1;
                    break;
                }
            }
        }

        // Load helix for aircraft/vehicles
        const helix_paths = [_][]const u8{
            patch_w3d_path ++ "NVHelix_D.W3D",
        };
        for (helix_paths) |path| {
            if (try self.w3d.load(path)) |model| {
                if (model.meshes.len > 0) {
                    self.model_cache.technical = .{ .model = model, .scale = 0.015 };
                    self.model_cache.scorpion = .{ .model = model, .scale = 0.012 };
                    self.model_cache.marauder = .{ .model = model, .scale = 0.015 };
                    std.debug.print("  Loaded: {s} ({d} meshes)\n", .{ path, model.meshes.len });
                    models_loaded_count += 1;
                    break;
                }
            }
        }

        self.models_loaded = true;
        if (models_loaded_count > 0) {
            std.debug.print("Model loading complete: {d} models loaded.\n", .{models_loaded_count});
        } else {
            std.debug.print("No models loaded - using placeholder graphics.\n", .{});
            std.debug.print("(To see 3D models, W3D assets need to be extracted from game BIG archives)\n", .{});
        }
    }

    pub fn deinit(self: *GameState) void {
        self.unit_positions.deinit(self.allocator);
        self.selected_units.deinit(self.allocator);
        self.active_build_queue.deinit(self.allocator);
        self.input_state.deinit();
        self.world.deinit();
        self.pathfinder.deinit();
        self.w3d.deinit();
        if (self.gl_context) |ctx| {
            cocoa.release(ctx);
        }
        if (self.window) |win| {
            cocoa.release(win);
        }
        self.allocator.destroy(self);
    }

    pub fn spawnUnit(self: *GameState, unit_type: UnitType, x: f32, y: f32, team: u8, faction: Faction) !game_ecs.Entity {
        const entity = try self.world.createEntity();

        // Determine max health based on unit type
        const max_health: f32 = switch (unit_type) {
            // Buildings have more health
            .command_center => 2000,
            .barracks, .war_factory, .airfield => 1000,
            .supply_depot => 1200,
            .power_plant => 500,
            .building => 1000,
            // Tanks are tough
            .crusader_tank, .battlemaster => 400,
            .paladin_tank, .overlord => 600,
            .scorpion_tank, .marauder_tank => 300,
            .tank => 400,
            // Vehicles
            .humvee, .technical => 200,
            .troop_crawler => 250,
            // Aircraft
            .comanche, .raptor, .mig, .helix => 160,
            .helicopter => 150,
            // Infantry
            .ranger, .red_guard, .rebel => 100,
            .missile_defender, .tank_hunter, .rpg_trooper => 100,
            .infantry => 100,
        };

        // Store position for rendering
        try self.unit_positions.append(self.allocator, .{
            .x = x,
            .y = y,
            .z = 0, // Ground level
            .unit_type = unit_type,
            .team = team,
            .faction = faction,
            .health = max_health,
            .max_health = max_health,
            .selected = false,
            .entity_id = entity.id,
            .rotation = 0, // Facing forward
        });

        std.debug.print("Spawned {s} ({s}) at ({d:.1}, {d:.1})\n", .{
            @tagName(unit_type),
            faction.getName(),
            x,
            y,
        });

        return entity;
    }

    pub fn update(self: *GameState, dt: f64) void {
        self.total_time += dt;

        // Handle input for camera movement
        const move_speed: f32 = 200.0 * @as(f32, @floatCast(dt));
        if (self.input_state.isKeyDown(.W) or self.input_state.isKeyDown(.UpArrow)) {
            self.camera_y += move_speed;
        }
        if (self.input_state.isKeyDown(.S) or self.input_state.isKeyDown(.DownArrow)) {
            self.camera_y -= move_speed;
        }
        if (self.input_state.isKeyDown(.A) or self.input_state.isKeyDown(.LeftArrow)) {
            self.camera_x -= move_speed;
        }
        if (self.input_state.isKeyDown(.D) or self.input_state.isKeyDown(.RightArrow)) {
            self.camera_x += move_speed;
        }

        // Zoom with +/-
        if (self.input_state.isKeyPressed(.Equal)) {
            self.camera_zoom *= 1.1;
        }
        if (self.input_state.isKeyPressed(.Minus)) {
            self.camera_zoom /= 1.1;
        }

        // Quit on Escape
        if (self.input_state.isKeyPressed(.Escape)) {
            self.running = false;
        }

        // Animate units slightly
        for (self.unit_positions.items) |*unit| {
            // Simple bobbing animation
            unit.y += @as(f32, @floatCast(@sin(self.total_time * 3.0 + unit.x * 0.1) * 0.1));
        }
    }

    pub fn render(self: *GameState, alpha: f64) void {
        _ = alpha;
        self.frame_count += 1;

        const w: f32 = @floatFromInt(WINDOW_WIDTH);
        const h: f32 = @floatFromInt(WINDOW_HEIGHT);

        // Clear screen with desert color
        gl.glClearColor(0.76, 0.70, 0.50, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        // =====================================================================
        // WORLD VIEW (game area - account for UI panels)
        // =====================================================================
        const game_area_width = w - UI.sidebar_width;
        const game_area_height = h - UI.bottom_panel_height - UI.top_bar_height;

        gl.glViewport(0, @intFromFloat(UI.bottom_panel_height), @intFromFloat(game_area_width), @intFromFloat(game_area_height));

        gl.glMatrixMode(gl.GL_PROJECTION);
        gl.glLoadIdentity();
        const half_width = game_area_width / 2.0 / self.camera_zoom;
        const half_height = game_area_height / 2.0 / self.camera_zoom;
        gl.glOrtho(
            @as(f64, self.camera_x - half_width),
            @as(f64, self.camera_x + half_width),
            @as(f64, self.camera_y - half_height),
            @as(f64, self.camera_y + half_height),
            -1.0,
            1.0,
        );

        gl.glMatrixMode(gl.GL_MODELVIEW);
        gl.glLoadIdentity();

        // Draw desert terrain with variation
        self.renderTerrain();

        // Draw units
        self.renderUnits();

        // =====================================================================
        // UI OVERLAY (full screen)
        // =====================================================================
        gl.glViewport(0, 0, @intFromFloat(w), @intFromFloat(h));
        gl.glMatrixMode(gl.GL_PROJECTION);
        gl.glLoadIdentity();
        gl.glOrtho(0, @as(f64, w), 0, @as(f64, h), -1, 1);
        gl.glMatrixMode(gl.GL_MODELVIEW);
        gl.glLoadIdentity();

        // Draw C&C Generals style UI
        self.renderTopBar(w, h);
        self.renderSidebar(w, h);
        self.renderBottomPanel(w, h);
        self.renderMinimap(w, h);
        self.renderCommandPanel(w, h);

        // Swap buffers
        if (self.gl_context) |ctx| {
            cocoa.flushBuffer(ctx);
        }
    }

    fn renderTerrain(self: *GameState) void {
        _ = self;

        // Desert sand base with subtle color variation
        const map_size: f32 = 1000;
        const tile_size: f32 = 50;

        // Draw terrain tiles
        var ty: f32 = -map_size / 2;
        while (ty < map_size / 2) : (ty += tile_size) {
            var tx: f32 = -map_size / 2;
            while (tx < map_size / 2) : (tx += tile_size) {
                // Variation based on position (pseudo-random)
                const variation = @sin(tx * 0.1) * @cos(ty * 0.1) * 0.05;
                const base_r: f32 = 0.82 + variation;
                const base_g: f32 = 0.75 + variation;
                const base_b: f32 = 0.58 + variation * 0.5;

                gl.glColor3f(base_r, base_g, base_b);
                drawRect(tx, ty, tile_size - 1, tile_size - 1);
            }
        }

        // Draw subtle grid lines
        gl.glColor4f(0.5, 0.45, 0.35, 0.3);
        gl.glLineWidth(1);
        gl.glBegin(gl.GL_LINES);
        var grid_x: f32 = -map_size / 2;
        while (grid_x <= map_size / 2) : (grid_x += tile_size) {
            gl.glVertex2f(grid_x, -map_size / 2);
            gl.glVertex2f(grid_x, map_size / 2);
        }
        var grid_y: f32 = -map_size / 2;
        while (grid_y <= map_size / 2) : (grid_y += tile_size) {
            gl.glVertex2f(-map_size / 2, grid_y);
            gl.glVertex2f(map_size / 2, grid_y);
        }
        gl.glEnd();

        // Draw some terrain features (rocks, dunes)
        // Rock clusters
        gl.glColor3f(0.45, 0.40, 0.35);
        drawCircle(-150, 100, 20);
        drawCircle(-140, 110, 15);
        drawCircle(-160, 95, 12);

        gl.glColor3f(0.50, 0.45, 0.38);
        drawCircle(200, -150, 25);
        drawCircle(220, -140, 18);
    }

    fn renderUnits(self: *GameState) void {
        for (self.unit_positions.items, 0..) |unit, idx| {
            _ = idx;
            const color = unit.faction.getColor();

            // Selection indicator (drawn first, below unit)
            if (unit.selected) {
                gl.glColor3f(UI.selection_color[0], UI.selection_color[1], UI.selection_color[2]);
                gl.glLineWidth(2);
                const sel_size = getUnitSize(unit.unit_type) + 5;
                drawCircleOutline(unit.x, unit.y, sel_size);
            }

            // Draw unit shadow
            gl.glColor4f(0.0, 0.0, 0.0, 0.3);
            const shadow_size = getUnitSize(unit.unit_type) * 0.8;
            drawOval(unit.x + 3, unit.y - 3, shadow_size, shadow_size * 0.5);

            // Try to render actual W3D model if available
            const model_opt = self.getModelForUnit(unit.unit_type);
            if (model_opt) |loaded_model| {
                // Only render if model has meshes
                if (loaded_model.model.meshes.len > 0) {
                    self.renderW3DModel(loaded_model, unit.x, unit.y, unit.z, unit.rotation, color);
                } else {
                    // Fallback if model has no meshes
                    gl.glColor3f(color[0], color[1], color[2]);
                    drawUnitShape(unit.unit_type, unit.x, unit.y);
                }
            } else {
                // Fallback to placeholder shapes
                gl.glColor3f(color[0], color[1], color[2]);
                drawUnitShape(unit.unit_type, unit.x, unit.y);
            }

            // Health bar background
            const bar_width: f32 = 30;
            const bar_height: f32 = 4;
            const bar_y = unit.y + getUnitSize(unit.unit_type) + 8;

            gl.glColor4f(0.0, 0.0, 0.0, 0.7);
            drawRect(unit.x - bar_width / 2 - 1, bar_y - 1, bar_width + 2, bar_height + 2);

            // Health bar fill
            const health_pct = unit.health / unit.max_health;
            if (health_pct > 0.5) {
                gl.glColor3f(0.2, 0.9, 0.2); // Green
            } else if (health_pct > 0.25) {
                gl.glColor3f(1.0, 0.8, 0.0); // Yellow
            } else {
                gl.glColor3f(1.0, 0.2, 0.2); // Red
            }
            drawRect(unit.x - bar_width / 2, bar_y, bar_width * health_pct, bar_height);
        }
    }

    /// Get the loaded W3D model for a unit type
    fn getModelForUnit(self: *GameState, unit_type: UnitType) ?LoadedModel {
        return switch (unit_type) {
            .ranger, .missile_defender, .infantry => self.model_cache.ranger,
            .crusader_tank => self.model_cache.crusader_tank,
            .paladin_tank => self.model_cache.paladin_tank,
            .battlemaster, .tank => self.model_cache.battlemaster,
            .overlord => self.model_cache.overlord,
            .red_guard, .tank_hunter => self.model_cache.red_guard,
            .technical, .humvee => self.model_cache.technical,
            .scorpion_tank => self.model_cache.scorpion,
            .marauder_tank => self.model_cache.marauder,
            else => null, // Buildings and other units use placeholders for now
        };
    }

    /// Render a W3D model at the given position using legacy OpenGL
    fn renderW3DModel(self: *GameState, loaded_model: LoadedModel, x: f32, y: f32, z: f32, rotation: f32, color: [3]f32) void {
        _ = self;

        const model = loaded_model.model;
        const scale = loaded_model.scale * 0.5; // Scale down for game view

        // Save matrix state
        gl.glPushMatrix();

        // Transform to unit position
        gl.glTranslatef(x, y, z);
        gl.glRotatef(rotation * 180.0 / std.math.pi, 0, 0, 1); // Rotate around Z axis
        gl.glScalef(scale, scale, scale);

        // Render each mesh in the model with faction color
        gl.glColor3f(color[0], color[1], color[2]);

        for (model.meshes) |mesh| {
            if (mesh.vertices.len == 0 or mesh.triangles.len == 0) continue;

            // Render triangles using immediate mode (legacy OpenGL)
            gl.glBegin(gl.GL_TRIANGLES);
            for (mesh.triangles) |tri| {
                // Render each vertex
                for (tri.indices) |idx| {
                    if (idx < mesh.vertices.len) {
                        const v = mesh.vertices[idx];
                        // Simple shading based on normal direction (pseudo-lighting)
                        const shade = 0.5 + v.normal.y * 0.3 + v.normal.z * 0.2;
                        gl.glColor3f(color[0] * shade, color[1] * shade, color[2] * shade);
                        gl.glVertex3f(v.position.x, v.position.y, v.position.z);
                    }
                }
            }
            gl.glEnd();
        }

        // Restore matrix state
        gl.glPopMatrix();
    }

    fn renderTopBar(self: *GameState, w: f32, h: f32) void {
        // Dark military green top bar (like Generals)
        gl.glColor4f(UI.panel_bg[0], UI.panel_bg[1], UI.panel_bg[2], UI.panel_bg[3]);
        drawRect(0, h - UI.top_bar_height, w, UI.top_bar_height);

        // Bottom border
        gl.glColor4f(UI.panel_border[0], UI.panel_border[1], UI.panel_border[2], 1.0);
        drawRect(0, h - UI.top_bar_height, w, 2);

        // Money display (left side) - green digits like in Generals
        const money_x: f32 = 20;
        const money_y = h - UI.top_bar_height + 8;

        // Dollar sign icon (simplified)
        gl.glColor3f(UI.money_color[0], UI.money_color[1], UI.money_color[2]);
        drawRect(money_x, money_y + 5, 15, 20);

        // Money amount display area
        gl.glColor4f(0.05, 0.08, 0.05, 0.9);
        drawRect(money_x + 20, money_y, 100, 24);
        gl.glColor3f(0.3, 0.5, 0.3);
        gl.glLineWidth(1);
        drawRectOutline(money_x + 20, money_y, 100, 24);

        // Draw money value as bar segments (visual representation)
        const money_fill = @min(1.0, @as(f32, @floatFromInt(self.player_resources.money)) / 10000.0);
        gl.glColor3f(UI.money_color[0], UI.money_color[1], UI.money_color[2]);
        var seg: u32 = 0;
        const num_segs: u32 = @intFromFloat(money_fill * 8);
        while (seg < num_segs) : (seg += 1) {
            drawRect(money_x + 25 + @as(f32, @floatFromInt(seg)) * 11, money_y + 4, 8, 16);
        }

        // Power display (middle-left)
        const power_x: f32 = 180;

        // Power icon (lightning bolt shape)
        gl.glColor3f(UI.power_positive[0], UI.power_positive[1], UI.power_positive[2]);
        gl.glBegin(gl.GL_TRIANGLES);
        gl.glVertex2f(power_x + 8, money_y + 24);
        gl.glVertex2f(power_x + 15, money_y + 12);
        gl.glVertex2f(power_x + 5, money_y + 12);
        gl.glVertex2f(power_x + 7, money_y + 12);
        gl.glVertex2f(power_x + 12, money_y);
        gl.glVertex2f(power_x + 2, money_y + 12);
        gl.glEnd();

        // Power bar background
        gl.glColor4f(0.05, 0.08, 0.05, 0.9);
        drawRect(power_x + 25, money_y, 120, 24);
        gl.glColor3f(0.3, 0.5, 0.3);
        drawRectOutline(power_x + 25, money_y, 120, 24);

        // Power bar fill
        const power_balance = self.player_resources.powerBalance();
        const power_pct = if (self.player_resources.power_produced > 0)
            @as(f32, @floatFromInt(self.player_resources.power_consumed)) / @as(f32, @floatFromInt(self.player_resources.power_produced))
        else
            1.0;

        if (power_balance >= 0) {
            gl.glColor3f(UI.power_positive[0], UI.power_positive[1], UI.power_positive[2]);
        } else {
            gl.glColor3f(UI.power_negative[0], UI.power_negative[1], UI.power_negative[2]);
        }
        drawRect(power_x + 27, money_y + 2, 116 * @min(1.0, power_pct), 20);

        // Generals rank stars (right side)
        const rank_x = w - UI.sidebar_width - 100;
        gl.glColor3f(1.0, 0.85, 0.0); // Gold stars
        var star: u8 = 0;
        while (star < self.player_resources.generals_rank) : (star += 1) {
            drawStar(rank_x + @as(f32, @floatFromInt(star)) * 22, money_y + 12, 8);
        }
    }

    fn renderSidebar(self: *GameState, w: f32, h: f32) void {
        _ = self;

        // Right sidebar panel
        const sidebar_x = w - UI.sidebar_width;

        // Background
        gl.glColor4f(UI.panel_bg[0], UI.panel_bg[1], UI.panel_bg[2], UI.panel_bg[3]);
        drawRect(sidebar_x, 0, UI.sidebar_width, h - UI.top_bar_height);

        // Left border
        gl.glColor4f(UI.panel_border[0], UI.panel_border[1], UI.panel_border[2], 1.0);
        drawRect(sidebar_x, 0, 2, h - UI.top_bar_height);

        // Radar/portrait area at top of sidebar
        const portrait_y = h - UI.top_bar_height - 120;
        gl.glColor4f(0.08, 0.10, 0.08, 1.0);
        drawRect(sidebar_x + 10, portrait_y, UI.sidebar_width - 20, 110);
        gl.glColor4f(UI.panel_border[0], UI.panel_border[1], UI.panel_border[2], 1.0);
        drawRectOutline(sidebar_x + 10, portrait_y, UI.sidebar_width - 20, 110);

        // USA faction logo placeholder
        gl.glColor3f(UI.team_usa[0], UI.team_usa[1], UI.team_usa[2]);
        drawStar(sidebar_x + UI.sidebar_width / 2, portrait_y + 55, 30);

        // Build buttons area
        const buttons_y = portrait_y - 20;
        const button_size: f32 = 54;
        const button_spacing: f32 = 60;
        const buttons_per_row: u32 = 3;

        var btn_idx: u32 = 0;
        while (btn_idx < 9) : (btn_idx += 1) {
            const row = btn_idx / buttons_per_row;
            const col = btn_idx % buttons_per_row;
            const bx = sidebar_x + 12 + @as(f32, @floatFromInt(col)) * button_spacing;
            const by = buttons_y - @as(f32, @floatFromInt(row + 1)) * button_spacing;

            // Button background
            gl.glColor4f(UI.button_bg[0], UI.button_bg[1], UI.button_bg[2], UI.button_bg[3]);
            drawRect(bx, by, button_size, button_size);

            // Button border
            gl.glColor4f(UI.button_border[0], UI.button_border[1], UI.button_border[2], 1.0);
            drawRectOutline(bx, by, button_size, button_size);

            // Icon placeholder (different shapes for different buttons)
            gl.glColor4f(0.5, 0.55, 0.5, 0.6);
            switch (btn_idx) {
                0 => drawCircle(bx + 27, by + 27, 18), // Infantry
                1 => drawRect(bx + 12, by + 17, 30, 20), // Vehicle
                2 => drawDiamond(bx + 27, by + 27, 15), // Aircraft
                3 => drawRect(bx + 10, by + 10, 34, 34), // Building
                else => drawRect(bx + 15, by + 15, 24, 24),
            }
        }
    }

    fn renderBottomPanel(self: *GameState, w: f32, h: f32) void {
        _ = self;
        _ = h;

        // Bottom panel (command area)
        gl.glColor4f(UI.panel_bg[0], UI.panel_bg[1], UI.panel_bg[2], UI.panel_bg[3]);
        drawRect(UI.minimap_size + 10, 0, w - UI.sidebar_width - UI.minimap_size - 20, UI.bottom_panel_height);

        // Top border
        gl.glColor4f(UI.panel_border[0], UI.panel_border[1], UI.panel_border[2], 1.0);
        drawRect(UI.minimap_size + 10, UI.bottom_panel_height - 2, w - UI.sidebar_width - UI.minimap_size - 20, 2);

        // Unit info area (when units selected)
        const info_x = UI.minimap_size + 20;
        const info_y: f32 = 10;

        // Unit portrait placeholder
        gl.glColor4f(0.08, 0.10, 0.08, 1.0);
        drawRect(info_x, info_y, 100, 100);
        gl.glColor4f(UI.panel_border[0], UI.panel_border[1], UI.panel_border[2], 1.0);
        drawRectOutline(info_x, info_y, 100, 100);

        // Placeholder unit icon
        gl.glColor3f(0.4, 0.5, 0.4);
        drawCircle(info_x + 50, info_y + 50, 30);

        // Unit stats area
        const stats_x = info_x + 120;

        // Attack bar
        gl.glColor3f(0.8, 0.2, 0.2);
        drawRect(stats_x, info_y + 70, 80, 8);
        gl.glColor3f(0.4, 0.45, 0.4);
        drawRect(stats_x, info_y + 70, 60, 8); // Fill

        // Defense bar
        gl.glColor3f(0.2, 0.2, 0.8);
        drawRect(stats_x, info_y + 50, 80, 8);
        gl.glColor3f(0.4, 0.45, 0.4);
        drawRect(stats_x, info_y + 50, 45, 8);

        // Speed bar
        gl.glColor3f(0.2, 0.8, 0.2);
        drawRect(stats_x, info_y + 30, 80, 8);
        gl.glColor3f(0.4, 0.45, 0.4);
        drawRect(stats_x, info_y + 30, 70, 8);
    }

    fn renderMinimap(self: *GameState, w: f32, h: f32) void {
        _ = w;
        _ = h;

        // Minimap frame (bottom-left, Generals style)
        const mm_x: f32 = 5;
        const mm_y: f32 = 5;
        const mm_size = UI.minimap_size;

        // Outer frame
        gl.glColor4f(UI.panel_bg[0], UI.panel_bg[1], UI.panel_bg[2], 1.0);
        drawRect(mm_x - 5, mm_y - 5, mm_size + 10, mm_size + 10);

        // Border with beveled look
        gl.glColor4f(UI.panel_highlight[0], UI.panel_highlight[1], UI.panel_highlight[2], 1.0);
        gl.glLineWidth(2);
        drawRectOutline(mm_x - 5, mm_y - 5, mm_size + 10, mm_size + 10);
        gl.glColor4f(0.2, 0.25, 0.2, 1.0);
        drawRectOutline(mm_x - 3, mm_y - 3, mm_size + 6, mm_size + 6);

        // Minimap background (terrain color)
        gl.glColor4f(0.6, 0.55, 0.45, 1.0);
        drawRect(mm_x, mm_y, mm_size, mm_size);

        // Draw units on minimap
        for (self.unit_positions.items) |unit| {
            const color = unit.faction.getColor();
            gl.glColor3f(color[0], color[1], color[2]);

            // Scale unit positions to minimap (map is -500 to 500)
            const mx = mm_x + mm_size / 2 + (unit.x / 500.0) * (mm_size / 2);
            const my = mm_y + mm_size / 2 + (unit.y / 500.0) * (mm_size / 2);

            // Different sizes for different unit types
            const dot_size: f32 = switch (unit.unit_type) {
                .command_center, .barracks, .war_factory, .airfield, .supply_depot, .power_plant, .building => 4,
                else => 2,
            };

            gl.glPointSize(dot_size * 2);
            gl.glBegin(gl.GL_POINTS);
            gl.glVertex2f(mx, my);
            gl.glEnd();
        }

        // Camera viewport indicator
        gl.glColor4f(UI.minimap_viewport[0], UI.minimap_viewport[1], UI.minimap_viewport[2], UI.minimap_viewport[3]);
        gl.glLineWidth(1);
        const cam_x = mm_x + mm_size / 2 + (self.camera_x / 500.0) * (mm_size / 2);
        const cam_y = mm_y + mm_size / 2 + (self.camera_y / 500.0) * (mm_size / 2);
        const view_w = (mm_size / self.camera_zoom) * 0.4;
        const view_h = view_w * 0.6;
        drawRectOutline(cam_x - view_w / 2, cam_y - view_h / 2, view_w, view_h);
    }

    fn renderCommandPanel(self: *GameState, w: f32, h: f32) void {
        _ = self;
        _ = h;

        // Command buttons (right side of bottom panel, left of sidebar)
        const cmd_x = w - UI.sidebar_width - 240;
        const cmd_y: f32 = 10;
        const btn_size: f32 = 40;
        const btn_spacing: f32 = 45;

        // Command buttons (Move, Attack, Stop, Guard, etc.)
        const commands = [_][]const u8{ "M", "A", "S", "G", "P", "F" };
        for (commands, 0..) |_, i| {
            const bx = cmd_x + @as(f32, @floatFromInt(i % 3)) * btn_spacing;
            const by = cmd_y + @as(f32, @floatFromInt(i / 3)) * btn_spacing;

            // Button background
            gl.glColor4f(UI.button_bg[0], UI.button_bg[1], UI.button_bg[2], UI.button_bg[3]);
            drawRect(bx, by, btn_size, btn_size);

            // Button border
            gl.glColor4f(UI.button_border[0], UI.button_border[1], UI.button_border[2], 1.0);
            drawRectOutline(bx, by, btn_size, btn_size);

            // Icon (simple shape placeholder)
            gl.glColor4f(0.6, 0.65, 0.6, 0.8);
            switch (i) {
                0 => { // Move - arrow
                    gl.glBegin(gl.GL_TRIANGLES);
                    gl.glVertex2f(bx + 20, by + 32);
                    gl.glVertex2f(bx + 10, by + 12);
                    gl.glVertex2f(bx + 30, by + 12);
                    gl.glEnd();
                },
                1 => { // Attack - crosshair
                    drawCircleOutline(bx + 20, by + 20, 12);
                    gl.glBegin(gl.GL_LINES);
                    gl.glVertex2f(bx + 20, by + 8);
                    gl.glVertex2f(bx + 20, by + 32);
                    gl.glVertex2f(bx + 8, by + 20);
                    gl.glVertex2f(bx + 32, by + 20);
                    gl.glEnd();
                },
                2 => { // Stop - square
                    drawRect(bx + 12, by + 12, 16, 16);
                },
                3 => { // Guard - shield shape
                    gl.glBegin(gl.GL_POLYGON);
                    gl.glVertex2f(bx + 10, by + 30);
                    gl.glVertex2f(bx + 10, by + 20);
                    gl.glVertex2f(bx + 20, by + 10);
                    gl.glVertex2f(bx + 30, by + 20);
                    gl.glVertex2f(bx + 30, by + 30);
                    gl.glEnd();
                },
                4 => { // Patrol - two arrows
                    gl.glBegin(gl.GL_LINES);
                    gl.glVertex2f(bx + 10, by + 25);
                    gl.glVertex2f(bx + 30, by + 25);
                    gl.glVertex2f(bx + 30, by + 15);
                    gl.glVertex2f(bx + 10, by + 15);
                    gl.glEnd();
                },
                5 => { // Force fire - explosion
                    drawCircle(bx + 20, by + 20, 8);
                    gl.glColor4f(1.0, 0.5, 0.0, 0.8);
                    drawCircle(bx + 20, by + 20, 5);
                },
                else => {},
            }
        }
    }
};

// Helper drawing functions using gl module's legacy functions

fn drawRect(x: f32, y: f32, w: f32, h: f32) void {
    gl.glBegin(gl.GL_QUADS);
    gl.glVertex2f(x, y);
    gl.glVertex2f(x + w, y);
    gl.glVertex2f(x + w, y + h);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
}

fn drawCircle(cx: f32, cy: f32, radius: f32) void {
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    gl.glVertex2f(cx, cy);
    var i: u32 = 0;
    while (i <= 16) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / 16.0;
        gl.glVertex2f(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
    }
    gl.glEnd();
}

fn drawDiamond(cx: f32, cy: f32, size: f32) void {
    gl.glBegin(gl.GL_QUADS);
    gl.glVertex2f(cx, cy + size);
    gl.glVertex2f(cx + size, cy);
    gl.glVertex2f(cx, cy - size);
    gl.glVertex2f(cx - size, cy);
    gl.glEnd();
}

fn drawRectOutline(x: f32, y: f32, w: f32, h: f32) void {
    gl.glBegin(gl.GL_LINE_LOOP);
    gl.glVertex2f(x, y);
    gl.glVertex2f(x + w, y);
    gl.glVertex2f(x + w, y + h);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
}

fn drawCircleOutline(cx: f32, cy: f32, radius: f32) void {
    gl.glBegin(gl.GL_LINE_LOOP);
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / 24.0;
        gl.glVertex2f(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
    }
    gl.glEnd();
}

fn drawOval(cx: f32, cy: f32, rx: f32, ry: f32) void {
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    gl.glVertex2f(cx, cy);
    var i: u32 = 0;
    while (i <= 16) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / 16.0;
        gl.glVertex2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
    }
    gl.glEnd();
}

fn drawStar(cx: f32, cy: f32, size: f32) void {
    const outer = size;
    const inner = size * 0.4;
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    gl.glVertex2f(cx, cy);
    var i: u32 = 0;
    while (i <= 10) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / 10.0 - std.math.pi / 2.0;
        const r = if (i % 2 == 0) outer else inner;
        gl.glVertex2f(cx + @cos(angle) * r, cy + @sin(angle) * r);
    }
    gl.glEnd();
}

fn getUnitSize(unit_type: UnitType) f32 {
    return switch (unit_type) {
        // Buildings are large
        .command_center => 40,
        .barracks, .war_factory, .airfield => 30,
        .supply_depot, .power_plant => 25,
        .building => 30,
        // Vehicles
        .crusader_tank, .paladin_tank, .battlemaster, .overlord => 18,
        .scorpion_tank, .marauder_tank => 15,
        .humvee, .technical, .troop_crawler => 14,
        .tank => 18,
        // Aircraft
        .comanche, .raptor, .mig, .helix => 14,
        .helicopter => 14,
        // Infantry
        .ranger, .red_guard, .rebel => 8,
        .missile_defender, .tank_hunter, .rpg_trooper => 8,
        .infantry => 8,
    };
}

fn drawUnitShape(unit_type: UnitType, x: f32, y: f32) void {
    const size = getUnitSize(unit_type);

    switch (unit_type) {
        // Infantry - small circles with soldier details
        .ranger, .missile_defender, .red_guard, .tank_hunter, .rebel, .rpg_trooper, .infantry => {
            drawCircle(x, y, size);
            // Head
            gl.glColor4f(0.9, 0.8, 0.7, 1.0);
            drawCircle(x, y + size * 0.3, size * 0.4);
        },
        // Tanks - rectangular with turret
        .crusader_tank, .paladin_tank, .battlemaster, .overlord, .scorpion_tank, .marauder_tank, .tank => {
            // Tank body
            drawRect(x - size, y - size * 0.6, size * 2, size * 1.2);
            // Turret
            drawCircle(x, y, size * 0.5);
            // Gun barrel
            drawRect(x, y - 2, size * 0.8, 4);
        },
        // Vehicles - rectangular
        .humvee, .technical, .troop_crawler => {
            drawRect(x - size, y - size * 0.5, size * 2, size);
            // Wheels
            gl.glColor4f(0.2, 0.2, 0.2, 1.0);
            drawCircle(x - size * 0.6, y - size * 0.4, 4);
            drawCircle(x + size * 0.6, y - size * 0.4, 4);
        },
        // Aircraft - diamond shape with rotor
        .comanche, .raptor, .mig, .helix, .helicopter => {
            drawDiamond(x, y, size);
            // Rotor
            gl.glColor4f(0.3, 0.3, 0.3, 0.7);
            drawRect(x - size * 1.2, y - 2, size * 2.4, 4);
            drawRect(x - 2, y - size * 1.2, 4, size * 2.4);
        },
        // Buildings - large squares with details
        .command_center => {
            drawRect(x - size, y - size, size * 2, size * 2);
            // Radar dish
            gl.glColor4f(0.5, 0.55, 0.5, 1.0);
            drawCircle(x, y + size * 0.3, size * 0.4);
            // Flag
            gl.glColor4f(1.0, 0.0, 0.0, 1.0);
            drawRect(x - 3, y + size * 0.5, 15, 10);
        },
        .barracks => {
            drawRect(x - size, y - size, size * 2, size * 2);
            // Door
            gl.glColor4f(0.3, 0.25, 0.2, 1.0);
            drawRect(x - size * 0.3, y - size, size * 0.6, size * 0.8);
        },
        .war_factory => {
            drawRect(x - size, y - size, size * 2, size * 2);
            // Bay door
            gl.glColor4f(0.3, 0.35, 0.3, 1.0);
            drawRect(x - size * 0.8, y - size, size * 1.6, size * 0.6);
        },
        .airfield => {
            drawRect(x - size, y - size, size * 2, size * 2);
            // Runway
            gl.glColor4f(0.4, 0.4, 0.4, 1.0);
            drawRect(x - size * 0.2, y - size, size * 0.4, size * 2);
        },
        .supply_depot => {
            drawRect(x - size, y - size, size * 2, size * 2);
            // Supply crates
            gl.glColor4f(0.6, 0.5, 0.3, 1.0);
            drawRect(x - size * 0.5, y - size * 0.5, size * 0.4, size * 0.4);
            drawRect(x + size * 0.1, y - size * 0.5, size * 0.4, size * 0.4);
        },
        .power_plant => {
            drawRect(x - size, y - size, size * 2, size * 2);
            // Cooling tower
            gl.glColor4f(0.7, 0.7, 0.7, 1.0);
            drawCircle(x, y, size * 0.6);
        },
        .building => {
            drawRect(x - size, y - size, size * 2, size * 2);
        },
    }
}

// ============================================================================
// Window and OpenGL initialization
// ============================================================================

fn initWindow(game_state: *GameState) !void {
    // Initialize NSApplication
    const app = cocoa.NSApp();
    cocoa.setActivationPolicy(.Regular);

    // Create window
    const rect = cocoa.CGRectMake(100, 100, @floatFromInt(WINDOW_WIDTH), @floatFromInt(WINDOW_HEIGHT));
    const window = cocoa.createWindow(rect, cocoa.NSWindowStyleMask.Default, .Buffered, false);
    if (window == null) {
        return error.WindowCreationFailed;
    }

    game_state.window = window;
    cocoa.setWindowTitle(window, "C&C Generals - Home Engine");
    cocoa.center(window);

    // Create OpenGL pixel format - use raw u32 array
    // NSOpenGLPixelFormatAttribute values from Apple documentation
    const NSOpenGLPFADoubleBuffer: u32 = 5;
    const NSOpenGLPFAColorSize: u32 = 8;
    const NSOpenGLPFAAlphaSize: u32 = 11;
    const NSOpenGLPFADepthSize: u32 = 12;
    const NSOpenGLPFAOpenGLProfile: u32 = 99;
    const NSOpenGLProfileVersionLegacy: u32 = 0x1000; // Legacy profile for glBegin/glEnd

    const pixel_attrs = [_]u32{
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize,
        24,
        NSOpenGLPFAAlphaSize,
        8,
        NSOpenGLPFADepthSize,
        24,
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersionLegacy, // Use legacy profile for compatibility with glBegin/glEnd
        0, // Terminate
    };

    const pixel_format = cocoa.createOpenGLPixelFormat(&pixel_attrs);
    if (pixel_format == null) {
        return error.PixelFormatCreationFailed;
    }
    defer cocoa.release(pixel_format);

    // Create OpenGL context
    const gl_context = cocoa.createOpenGLContext(pixel_format, null);
    if (gl_context == null) {
        return error.GLContextCreationFailed;
    }
    game_state.gl_context = gl_context;

    // Attach context to window's content view
    const content_view = cocoa.contentView(window);
    cocoa.setView(gl_context, content_view);
    cocoa.makeCurrentContext(gl_context);

    // Show window
    cocoa.makeKeyAndOrderFront(window);
    cocoa.activateIgnoringOtherApps(app, true);

    // Set up OpenGL state
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glViewport(0, 0, @intCast(WINDOW_WIDTH), @intCast(WINDOW_HEIGHT));

    std.debug.print("Window created: {d}x{d}\n", .{ WINDOW_WIDTH, WINDOW_HEIGHT });
    std.debug.print("OpenGL context initialized\n", .{});
}

fn processEvents(game_state: *GameState) void {
    const app = cocoa.NSApp();
    const distant_past = cocoa.distantPast();
    const run_loop_mode = cocoa.defaultRunLoopMode();

    // Poll all pending events
    while (true) {
        const event = cocoa.nextEventMatchingMask(app, 0xFFFFFFFF, distant_past, run_loop_mode, true);
        if (event == null) break;

        // Get event type
        const event_type = cocoa.eventType(event);

        // Handle quit events
        if (event_type == .KeyDown) {
            const key_code = cocoa.keyCode(event);
            // Escape key
            if (key_code == cocoa.kVK_Escape) {
                game_state.running = false;
            }
            // Handle key events for input state
            const modifiers = cocoa.modifierFlags(event);
            const input_event = input_mod.InputEvent{
                .KeyDown = .{
                    .key = input_mod.KeyCode.fromMacOS(key_code),
                    .modifiers = .{
                        .shift = modifiers.shift,
                        .control = modifiers.control,
                        .alt = modifiers.option,
                        .command = modifiers.command,
                        .caps_lock = modifiers.caps_lock,
                    },
                    .repeat = false,
                },
            };
            game_state.input_state.processEvent(input_event) catch {};
        } else if (event_type == .KeyUp) {
            const key_code = cocoa.keyCode(event);
            const modifiers = cocoa.modifierFlags(event);
            const input_event = input_mod.InputEvent{
                .KeyUp = .{
                    .key = input_mod.KeyCode.fromMacOS(key_code),
                    .modifiers = .{
                        .shift = modifiers.shift,
                        .control = modifiers.control,
                        .alt = modifiers.option,
                        .command = modifiers.command,
                        .caps_lock = modifiers.caps_lock,
                    },
                },
            };
            game_state.input_state.processEvent(input_event) catch {};
        }

        // Forward event to application
        cocoa.sendEvent(app, event);
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        C&C Generals - Home Engine                        ║\n", .{});
    std.debug.print("║        Powered by Craft Framework (Cocoa/OpenGL)         ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n\n", .{});

    std.debug.print("Initializing game systems...\n", .{});

    // Initialize game state
    var game_state = try GameState.init(allocator);
    defer game_state.deinit();

    // Spawn units - USA vs China scenario
    std.debug.print("\nSpawning units...\n", .{});

    // ========== USA Base (Player - Blue) ==========
    // Command Center
    _ = try game_state.spawnUnit(.command_center, -250, -200, 1, .usa);
    // Production buildings
    _ = try game_state.spawnUnit(.barracks, -320, -180, 1, .usa);
    _ = try game_state.spawnUnit(.war_factory, -320, -250, 1, .usa);
    _ = try game_state.spawnUnit(.airfield, -180, -280, 1, .usa);
    // Economy
    _ = try game_state.spawnUnit(.supply_depot, -180, -150, 1, .usa);
    _ = try game_state.spawnUnit(.power_plant, -380, -200, 1, .usa);
    _ = try game_state.spawnUnit(.power_plant, -380, -260, 1, .usa);
    // Infantry
    _ = try game_state.spawnUnit(.ranger, -200, -120, 1, .usa);
    _ = try game_state.spawnUnit(.ranger, -220, -110, 1, .usa);
    _ = try game_state.spawnUnit(.ranger, -180, -130, 1, .usa);
    _ = try game_state.spawnUnit(.missile_defender, -240, -100, 1, .usa);
    _ = try game_state.spawnUnit(.missile_defender, -160, -100, 1, .usa);
    // Vehicles
    _ = try game_state.spawnUnit(.humvee, -150, -80, 1, .usa);
    _ = try game_state.spawnUnit(.crusader_tank, -100, -60, 1, .usa);
    _ = try game_state.spawnUnit(.crusader_tank, -130, -50, 1, .usa);
    _ = try game_state.spawnUnit(.paladin_tank, -80, -40, 1, .usa);
    // Aircraft
    _ = try game_state.spawnUnit(.comanche, -50, -100, 1, .usa);
    _ = try game_state.spawnUnit(.raptor, -30, -120, 1, .usa);

    // ========== China Base (Enemy - Red) ==========
    // Command Center
    _ = try game_state.spawnUnit(.command_center, 250, 200, 2, .china);
    // Production buildings
    _ = try game_state.spawnUnit(.barracks, 320, 180, 2, .china);
    _ = try game_state.spawnUnit(.war_factory, 320, 250, 2, .china);
    _ = try game_state.spawnUnit(.airfield, 180, 280, 2, .china);
    // Economy
    _ = try game_state.spawnUnit(.supply_depot, 180, 150, 2, .china);
    _ = try game_state.spawnUnit(.power_plant, 380, 200, 2, .china);
    _ = try game_state.spawnUnit(.power_plant, 380, 260, 2, .china);
    // Infantry
    _ = try game_state.spawnUnit(.red_guard, 200, 120, 2, .china);
    _ = try game_state.spawnUnit(.red_guard, 220, 110, 2, .china);
    _ = try game_state.spawnUnit(.red_guard, 180, 130, 2, .china);
    _ = try game_state.spawnUnit(.red_guard, 200, 140, 2, .china);
    _ = try game_state.spawnUnit(.tank_hunter, 240, 100, 2, .china);
    _ = try game_state.spawnUnit(.tank_hunter, 160, 100, 2, .china);
    // Vehicles
    _ = try game_state.spawnUnit(.troop_crawler, 150, 80, 2, .china);
    _ = try game_state.spawnUnit(.battlemaster, 100, 60, 2, .china);
    _ = try game_state.spawnUnit(.battlemaster, 130, 50, 2, .china);
    _ = try game_state.spawnUnit(.battlemaster, 80, 70, 2, .china);
    _ = try game_state.spawnUnit(.overlord, 60, 40, 2, .china);
    // Aircraft
    _ = try game_state.spawnUnit(.mig, 30, 100, 2, .china);
    _ = try game_state.spawnUnit(.helix, 50, 120, 2, .china);

    std.debug.print("\nTotal entities: {d}\n", .{game_state.world.entityCount()});

    // Test pathfinding
    std.debug.print("\nTesting pathfinding...\n", .{});
    if (game_state.pathfinder.findPath(0, 0, 10, 10)) |maybe_path| {
        if (maybe_path) |path| {
            std.debug.print("  Found path with {d} waypoints\n", .{path.len});
            game_state.allocator.free(path);
        } else {
            std.debug.print("  No path found\n", .{});
        }
    } else |err| {
        std.debug.print("  Pathfinding error: {}\n", .{err});
    }

    // Test AI system
    std.debug.print("\nAI systems initialized:\n", .{});
    std.debug.print("  - Behavior trees (NodeStatus: {s})\n", .{@tagName(game_ai.NodeStatus.success)});
    std.debug.print("  - State machines\n", .{});
    std.debug.print("  - Utility AI\n", .{});

    // Initialize mod system
    var mod_manager = try game_mods.ModManager.init(allocator);
    defer mod_manager.deinit();

    try mod_manager.registerMod(.{
        .id = "zero_hour",
        .name = "Zero Hour Expansion",
        .version = .{ .major = 1, .minor = 4, .patch = 0 },
        .author = "Home Team",
        .description = "Zero Hour expansion pack",
        .dependencies = &[_]game_mods.Dependency{},
        .conflicts = &[_][]const u8{},
        .load_priority = 100,
        .enabled = true,
        .path = "mods/zero_hour",
    });

    std.debug.print("\nMods loaded:\n", .{});
    if (mod_manager.getMod("zero_hour")) |mod| {
        std.debug.print("  - {s} v{d}.{d}.{d}\n", .{
            mod.info.name,
            mod.info.version.major,
            mod.info.version.minor,
            mod.info.version.patch,
        });
    }

    // Initialize network
    var server = try game_network.NetworkServer.init(allocator, 8);
    defer server.deinit();
    std.debug.print("\nNetwork: Server ready (max {d} players)\n", .{8});

    // Create window and OpenGL context
    std.debug.print("\nInitializing graphics...\n", .{});
    try initWindow(game_state);

    // Load W3D models from game assets
    std.debug.print("\nLoading 3D models...\n", .{});
    try game_state.loadModels();

    // Set up OpenGL for 3D rendering
    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glDepthFunc(gl.GL_LEQUAL);

    std.debug.print("\n╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Controls:                                               ║\n", .{});
    std.debug.print("║    WASD / Arrow Keys - Move camera                       ║\n", .{});
    std.debug.print("║    +/- - Zoom in/out                                     ║\n", .{});
    std.debug.print("║    ESC - Quit                                            ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n\n", .{});

    std.debug.print("Starting game loop...\n\n", .{});

    // Game loop timing
    var last_time = game_loop.getNanoTimestamp();
    const target_dt: f64 = 1.0 / 60.0; // 60 FPS
    var fps_timer: f64 = 0;
    var frame_count: u32 = 0;

    // Main game loop
    while (game_state.running) {
        // Calculate delta time
        const current_time = game_loop.getNanoTimestamp();
        const dt = @as(f64, @floatFromInt(current_time - last_time)) / 1_000_000_000.0;
        last_time = current_time;

        // FPS counter
        fps_timer += dt;
        frame_count += 1;
        if (fps_timer >= 1.0) {
            std.debug.print("\rFPS: {d} | Camera: ({d:.0}, {d:.0}) | Zoom: {d:.2}x    ", .{
                frame_count,
                game_state.camera_x,
                game_state.camera_y,
                game_state.camera_zoom,
            });
            frame_count = 0;
            fps_timer = 0;
        }

        // Begin input frame
        game_state.input_state.beginFrame();

        // Process window events
        processEvents(game_state);

        // Update game state
        game_state.update(dt);

        // Render
        game_state.render(1.0);

        // Frame limiting
        const frame_time = @as(f64, @floatFromInt(game_loop.getNanoTimestamp() - current_time)) / 1_000_000_000.0;
        if (frame_time < target_dt) {
            const sleep_ns: u64 = @intFromFloat((target_dt - frame_time) * 1_000_000_000.0);
            std.posix.nanosleep(0, sleep_ns);
        }
    }

    std.debug.print("\n\nGame ended. Thanks for playing!\n", .{});
}
