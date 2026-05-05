const std = @import("std");
const builtin = @import("builtin");

const Config = struct {
    poll_interval_ms: u64 = 1000,
    obs_executable: []const u8 = "/Applications/OBS.app/Contents/MacOS/OBS",
    profiles: []const WatchConfig = &.{},
    configs: []const WatchConfig = &.{},
};

const OutputConfig = struct {
    poll_interval_ms: u64 = 1000,
    obs_executable: []const u8 = "/Applications/OBS.app/Contents/MacOS/OBS",
    profiles: []const WatchConfig,
};

const WatchConfig = struct {
    name: []const u8,
    app: []const u8,
    app_match: []const u8 = "exact",
    app_source: []const u8 = "process",
    app_title: []const u8 = "",
    app_title_match: []const u8 = "any",
    scene: []const u8,
    start_recording: bool = false,
    obs_executable: ?[]const u8 = null,
    obs_args: []const []const u8 = &.{},
};

const InstanceState = struct {
    obs_pid: ?std.process.Child.Id = null,
    app_was_open: bool = false,
};

const default_config_subpath = ".config/obsautolaunch/config.json";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if ((args.len == 2 or args.len == 3) and std.mem.eql(u8, args[1], "config")) {
        try ensureMacos();
        const config_path = try resolveConfigPath(arena, init.environ_map, if (args.len == 3) args[2] else null);
        try runInteractiveConfig(arena, gpa, init.io, init.environ_map, config_path);
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "status")) {
        const running = try printDaemonStatus(gpa, init.io);
        if (!running) std.process.exit(1);
        return;
    }

    if ((args.len != 2 and args.len != 3) or !std.mem.eql(u8, args[1], "daemon")) {
        printUsage(args[0]);
        return error.InvalidArguments;
    }

    try ensureMacos();

    const config_path = try resolveConfigPath(arena, init.environ_map, if (args.len == 3) args[2] else null);
    try runDaemon(gpa, init.io, config_path);
}

fn printUsage(bin: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  {s} config [config.json]
        \\  {s} daemon [config.json]
        \\  {s} status
        \\
        \\When omitted, config path defaults to ~/.config/obsautolaunch/config.json.
        \\
    , .{ bin, bin, bin });
}

fn ensureMacos() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("obs-autoluanch currently supports macOS only.\n", .{});
        return error.UnsupportedOs;
    }
}

fn loadConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Config) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);

    return std.json.parseFromSlice(Config, gpa, bytes, .{
        .ignore_unknown_fields = true,
    });
}

fn loadConfigLeaky(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);

    return std.json.parseFromSliceLeaky(Config, arena, bytes, .{
        .ignore_unknown_fields = true,
    });
}

fn activeProfiles(config: Config) []const WatchConfig {
    if (config.profiles.len != 0) return config.profiles;
    return config.configs;
}

fn resolveConfigPath(
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    explicit_path: ?[]const u8,
) ![]const u8 {
    if (explicit_path) |path| return path;
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(arena, &.{ home, default_config_subpath });
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn runDaemon(gpa: std.mem.Allocator, io: std.Io, config_path: []const u8) !void {
    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();

    var config: Config = .{};
    var profiles: []const WatchConfig = &.{};
    var config_mtime: ?std.Io.Timestamp = null;
    var logged_missing_config = false;

    var states = try gpa.alloc(InstanceState, 0);
    defer gpa.free(states);

    while (true) {
        const current_mtime = fileMtime(io, config_path) catch |err| {
            if (!logged_missing_config or profiles.len != 0) {
                std.debug.print("waiting for config at {s}: {s}\n", .{ config_path, @errorName(err) });
                logged_missing_config = true;
            }
            if (profiles.len != 0) {
                gpa.free(states);
                states = try gpa.alloc(InstanceState, 0);
                config_arena.deinit();
                config_arena = std.heap.ArenaAllocator.init(gpa);
                config = .{};
                profiles = &.{};
                config_mtime = null;
            }
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .boot);
            continue;
        };

        if (config_mtime == null or current_mtime.nanoseconds != config_mtime.?.nanoseconds) {
            const old_profiles = profiles;
            const old_states = states;

            var next_arena = std.heap.ArenaAllocator.init(gpa);
            const next_config = loadConfigLeaky(next_arena.allocator(), gpa, io, config_path) catch |err| {
                next_arena.deinit();
                std.debug.print("failed to reload config: {s}\n", .{@errorName(err)});
                config_mtime = current_mtime;
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .boot);
                continue;
            };
            const next_profiles = activeProfiles(next_config);
            if (next_profiles.len == 0) {
                next_arena.deinit();
                std.debug.print("config loaded but has no profiles; waiting for edits\n", .{});
                config_mtime = current_mtime;
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(next_config.poll_interval_ms)), .boot);
                continue;
            }

            const next_states = try gpa.alloc(InstanceState, next_profiles.len);
            @memset(next_states, .{});
            for (next_profiles, 0..) |profile, index| {
                if (findProfileIndex(old_profiles, profile.name)) |old_index| {
                    next_states[index] = old_states[old_index];
                }
            }

            gpa.free(states);
            config_arena.deinit();
            config_arena = next_arena;
            config = next_config;
            profiles = next_profiles;
            states = next_states;
            config_mtime = current_mtime;
            logged_missing_config = false;
            std.debug.print("loaded config; watching {d} profile(s); polling every {d} ms\n", .{
                profiles.len,
                config.poll_interval_ms,
            });
        }

        for (profiles, 0..) |watch, index| {
            const open = isWatchedAppOpen(gpa, io, watch) catch |err| {
                std.debug.print("failed to check app '{s}': {s}\n", .{ watch.app, @errorName(err) });
                continue;
            };

            if (!open) {
                states[index].app_was_open = false;
                continue;
            }

            const pid = states[index].obs_pid;
            const running = if (pid) |p| processExists(gpa, io, p) catch false else false;

            if (!running) {
                states[index].obs_pid = try launchObs(gpa, io, config, watch);
                states[index].app_was_open = true;
                continue;
            }

            if (!states[index].app_was_open) {
                try focusProcess(gpa, io, states[index].obs_pid.?);
                if (watch.start_recording) {
                    std.debug.print(
                        "config '{s}' is already running; recording is requested at OBS launch time\n",
                        .{watch.name},
                    );
                }
            }

            states[index].app_was_open = true;
        }

        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(config.poll_interval_ms)), .boot);
    }
}

fn fileMtime(io: std.Io, path: []const u8) !std.Io.Timestamp {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return (try file.stat(io)).mtime;
}

fn findProfileIndex(profiles: []const WatchConfig, name: []const u8) ?usize {
    for (profiles, 0..) |profile, index| {
        if (std.mem.eql(u8, profile.name, name)) return index;
    }
    return null;
}

fn runInteractiveConfig(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    output_path: []const u8,
) !void {
    const existing_config = loadConfigLeaky(arena, gpa, io, output_path) catch |err| switch (err) {
        error.FileNotFound => Config{},
        else => |e| return e,
    };

    const apps = try listRunningApps(arena, gpa, io);
    if (apps.len == 0) return error.NoAppsAvailable;

    const scenes = try listObsScenes(arena, gpa, io, environ);
    defer gpa.free(scenes);
    if (scenes.len == 0) {
        std.debug.print("No OBS scenes found in ~/Library/Application Support/obs-studio/basic/scenes\n", .{});
        return error.NoScenesAvailable;
    }

    var watches: std.ArrayList(WatchConfig) = .empty;
    defer watches.deinit(gpa);
    for (activeProfiles(existing_config)) |profile| try watches.append(gpa, profile);

    while (true) {
        const action = try chooseFromList(arena, gpa, io, "Profile config", &.{ "Add profile", "Edit profile", "Delete profile", "Save and quit" });
        if (std.mem.eql(u8, action, "Save and quit")) break;

        if (std.mem.eql(u8, action, "Add profile")) {
            try watches.append(gpa, try promptProfile(arena, gpa, io, apps, scenes, null));
            continue;
        }

        if (watches.items.len == 0) {
            std.debug.print("no profiles to edit yet\n", .{});
            continue;
        }

        const labels = try profileLabels(arena, watches.items);
        const selected = try chooseFromList(arena, gpa, io, "Choose profile", labels);
        const index = findProfileLabelIndex(watches.items, selected) orelse return error.ProfileSelectionFailed;

        if (std.mem.eql(u8, action, "Edit profile")) {
            watches.items[index] = try promptProfile(arena, gpa, io, apps, scenes, watches.items[index]);
        } else if (std.mem.eql(u8, action, "Delete profile")) {
            _ = watches.orderedRemove(index);
        }
    }

    const profiles = try watches.toOwnedSlice(gpa);
    defer gpa.free(profiles);

    const config = OutputConfig{
        .poll_interval_ms = existing_config.poll_interval_ms,
        .obs_executable = existing_config.obs_executable,
        .profiles = profiles,
    };

    const json = try std.json.Stringify.valueAlloc(gpa, config, .{ .whitespace = .indent_2 });
    defer gpa.free(json);

    try ensureParentDir(io, output_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = json });
    std.debug.print("wrote config to {s}\n", .{output_path});
}

fn promptProfile(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    apps: []const []const u8,
    scenes: []const ObsScene,
    existing: ?WatchConfig,
) !WatchConfig {
    const picked_app = try chooseFromList(arena, gpa, io, "Choose the app to watch", apps);
    const source_mode = try chooseFromList(
        arena,
        gpa,
        io,
        "Which app name should be watched?",
        &.{ "Mac menu bar app name", "Process executable name" },
    );
    const app_source = if (std.mem.eql(u8, source_mode, "Mac menu bar app name")) "display" else "process";
    const match_mode = try chooseFromList(
        arena,
        gpa,
        io,
        "How should this app process be matched?",
        &.{ "Exact app name", "Any app starting with first 2 words" },
    );
    const prefix_match = std.mem.eql(u8, match_mode, "Any app starting with first 2 words");
    const app_default = if (prefix_match) try firstWords(arena, picked_app, 2) else picked_app;
    const app = try promptText(arena, gpa, io, "App/process name or prefix", if (existing) |profile| profile.app else app_default);

    const title_mode = try chooseFromList(
        arena,
        gpa,
        io,
        "Window title filter",
        &.{ "Any title", "Title contains text", "Exact title", "Title starts with text" },
    );
    const app_title_match = titleMatchKey(title_mode);
    const app_title = if (std.mem.eql(u8, app_title_match, "any"))
        ""
    else
        try promptText(arena, gpa, io, "Window title text", if (existing) |profile| profile.app_title else "");

    const scene_labels = try sceneLabels(arena, scenes);
    const selected_scene_label = try chooseFromList(arena, gpa, io, "Choose the OBS scene to launch", scene_labels);
    const scene = findSceneByLabel(scenes, selected_scene_label) orelse return error.SceneSelectionFailed;

    const default_name = if (existing) |profile| profile.name else try std.fmt.allocPrint(arena, "{s} -> {s}", .{ app, scene.name });
    const name = try promptText(arena, gpa, io, "Profile name", default_name);

    const recording_answer = try chooseFromList(arena, gpa, io, "Start recording when OBS launches?", &.{ "No", "Yes" });
    const start_recording = std.mem.eql(u8, recording_answer, "Yes");

    const obs_args = try arena.alloc([]const u8, 2);
    obs_args[0] = "--collection";
    obs_args[1] = scene.collection;

    return .{
        .name = name,
        .app = app,
        .app_match = if (prefix_match) "prefix" else "exact",
        .app_source = app_source,
        .app_title = app_title,
        .app_title_match = app_title_match,
        .scene = scene.name,
        .start_recording = start_recording,
        .obs_args = obs_args,
    };
}

fn titleMatchKey(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "Title contains text")) return "contains";
    if (std.mem.eql(u8, label, "Exact title")) return "exact";
    if (std.mem.eql(u8, label, "Title starts with text")) return "prefix";
    return "any";
}

fn profileLabels(arena: std.mem.Allocator, profiles: []const WatchConfig) ![]const []const u8 {
    var labels = try arena.alloc([]const u8, profiles.len);
    for (profiles, 0..) |profile, i| {
        labels[i] = try std.fmt.allocPrint(arena, "{s} ({s})", .{ profile.name, profile.app });
    }
    return labels;
}

fn findProfileLabelIndex(profiles: []const WatchConfig, label: []const u8) ?usize {
    for (profiles, 0..) |profile, i| {
        if (std.mem.startsWith(u8, label, profile.name) and std.mem.containsAtLeast(u8, label, 1, profile.app)) return i;
    }
    return null;
}

fn listRunningApps(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const script =
        \\tell application "System Events"
        \\  set appNames to name of every application process whose background only is false
        \\end tell
        \\set AppleScript's text item delimiters to linefeed
        \\return appNames as text
    ;
    const output = try runOsascript(gpa, io, script);
    defer gpa.free(output);
    return splitNonEmptyLines(arena, output);
}

const ObsScene = struct {
    collection: []const u8,
    name: []const u8,
    label: []const u8,
};

fn listObsScenes(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
) ![]const ObsScene {
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const scene_dir = try std.fs.path.join(gpa, &.{ home, "Library/Application Support/obs-studio/basic/scenes" });
    defer gpa.free(scene_dir);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "find", scene_dir, "-name", "*.json", "-type", "f" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SceneDiscoveryFailed,
        else => return error.SceneDiscoveryFailed,
    }

    var scenes: std.ArrayList(ObsScene) = .empty;
    defer scenes.deinit(gpa);

    var paths = std.mem.splitScalar(u8, result.stdout, '\n');
    while (paths.next()) |path_raw| {
        const path = std.mem.trim(u8, path_raw, " \t\r");
        if (path.len == 0) continue;
        try appendScenesFromCollection(arena, gpa, io, &scenes, path);
    }

    return scenes.toOwnedSlice(gpa);
}

fn appendScenesFromCollection(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    scenes: *std.ArrayList(ObsScene),
    path: []const u8,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return;
    defer parsed.deinit();

    const collection = try arena.dupe(u8, std.fs.path.stem(path));
    if (parsed.value != .object) return;

    if (parsed.value.object.get("scene_order")) |scene_order| {
        if (scene_order == .array) {
            for (scene_order.array.items) |entry| {
                if (entry != .object) continue;
                const name_value = entry.object.get("name") orelse continue;
                if (name_value != .string) continue;
                try appendObsScene(arena, gpa, scenes, collection, name_value.string);
            }
            return;
        }
    }

    if (parsed.value.object.get("sources")) |sources| {
        if (sources == .array) {
            for (sources.array.items) |entry| {
                if (entry != .object) continue;
                const id_value = entry.object.get("id") orelse continue;
                if (id_value != .string or !std.mem.eql(u8, id_value.string, "scene")) continue;
                const name_value = entry.object.get("name") orelse continue;
                if (name_value != .string) continue;
                try appendObsScene(arena, gpa, scenes, collection, name_value.string);
            }
        }
    }
}

fn appendObsScene(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    scenes: *std.ArrayList(ObsScene),
    collection: []const u8,
    scene_name: []const u8,
) !void {
    for (scenes.items) |scene| {
        if (std.mem.eql(u8, scene.collection, collection) and std.mem.eql(u8, scene.name, scene_name)) return;
    }

    const name = try arena.dupe(u8, scene_name);
    const label = try std.fmt.allocPrint(arena, "{s} / {s}", .{ collection, name });
    try scenes.append(gpa, .{
        .collection = collection,
        .name = name,
        .label = label,
    });
}

fn sceneLabels(arena: std.mem.Allocator, scenes: []const ObsScene) ![]const []const u8 {
    var labels = try arena.alloc([]const u8, scenes.len);
    for (scenes, 0..) |scene, i| labels[i] = scene.label;
    return labels;
}

fn findSceneByLabel(scenes: []const ObsScene, label: []const u8) ?ObsScene {
    for (scenes) |scene| {
        if (std.mem.eql(u8, scene.label, label)) return scene;
    }
    return null;
}

fn chooseFromList(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
    items: []const []const u8,
) ![]const u8 {
    if (items.len == 0) return error.EmptyChoiceList;

    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);

    try script.appendSlice(gpa, "set picked to choose from list {");
    for (items, 0..) |item, i| {
        if (i != 0) try script.appendSlice(gpa, ", ");
        try appendAppleScriptString(gpa, &script, item);
    }
    try script.appendSlice(gpa, "} with prompt ");
    try appendAppleScriptString(gpa, &script, prompt);
    try script.appendSlice(gpa, " OK button name \"Select\" cancel button name \"Cancel\" without multiple selections allowed\n");
    try script.appendSlice(gpa, "if picked is false then error number -128\nreturn item 1 of picked\n");

    const output = try runOsascript(gpa, io, script.items);
    defer gpa.free(output);
    return arena.dupe(u8, std.mem.trim(u8, output, " \t\r\n"));
}

fn promptText(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
    default_value: []const u8,
) ![]const u8 {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);

    try script.appendSlice(gpa, "set answer to text returned of (display dialog ");
    try appendAppleScriptString(gpa, &script, prompt);
    try script.appendSlice(gpa, " default answer ");
    try appendAppleScriptString(gpa, &script, default_value);
    try script.appendSlice(gpa, ")\nreturn answer\n");

    const output = try runOsascript(gpa, io, script.items);
    defer gpa.free(output);
    return arena.dupe(u8, std.mem.trim(u8, output, " \t\r\n"));
}

fn runOsascript(gpa: std.mem.Allocator, io: std.Io, script: []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "osascript", "-e", script },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return result.stdout;
            gpa.free(result.stdout);
            if (std.mem.containsAtLeast(u8, result.stderr, 1, "-128")) return error.UserCanceled;
            std.debug.print("osascript failed: {s}\n", .{result.stderr});
            return error.OsascriptFailed;
        },
        else => return error.OsascriptFailed,
    }
}

fn appendAppleScriptString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(gpa, '"');
    for (value) |byte| switch (byte) {
        '\\', '"' => {
            try out.append(gpa, '\\');
            try out.append(gpa, byte);
        },
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => {},
        else => try out.append(gpa, byte),
    };
    try out.append(gpa, '"');
}

fn splitNonEmptyLines(arena: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(arena);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        for (items.items) |existing| {
            if (std.mem.eql(u8, existing, line)) break;
        } else {
            try items.append(arena, try arena.dupe(u8, line));
        }
    }

    return items.toOwnedSlice(arena);
}

fn firstWords(arena: std.mem.Allocator, input: []const u8, count: usize) ![]const u8 {
    var seen: usize = 0;
    var end: usize = 0;
    var in_word = false;

    for (input, 0..) |byte, i| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
        if (is_space) {
            if (in_word) {
                seen += 1;
                if (seen == count) {
                    end = i;
                    break;
                }
                in_word = false;
            }
        } else {
            if (!in_word) in_word = true;
            end = i + 1;
        }
    }

    if (in_word and seen < count) end = input.len;
    return arena.dupe(u8, std.mem.trim(u8, input[0..end], " \t\r\n"));
}

fn printDaemonStatus(gpa: std.mem.Allocator, io: std.Io) !bool {
    const pids = try findDaemonPids(gpa, io);
    defer gpa.free(pids);

    if (pids.len == 0) {
        std.debug.print("obs-autoluanch daemon is not running\n", .{});
        return false;
    }

    std.debug.print("obs-autoluanch daemon is running", .{});
    for (pids) |pid| std.debug.print(" {d}", .{pid});
    std.debug.print("\n", .{});
    return true;
}

fn findDaemonPids(gpa: std.mem.Allocator, io: std.Io) ![]std.process.Child.Id {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "ps", "ax", "-o", "pid=", "-o", "command=" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.StatusCheckFailed,
        else => return error.StatusCheckFailed,
    }

    return parseDaemonPids(gpa, result.stdout);
}

fn parseDaemonPids(gpa: std.mem.Allocator, ps_output: []const u8) ![]std.process.Child.Id {
    var pids: std.ArrayList(std.process.Child.Id) = .empty;
    errdefer pids.deinit(gpa);

    var lines = std.mem.splitScalar(u8, ps_output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        const split_at = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const pid_text = line[0..split_at];
        const command = std.mem.trim(u8, line[split_at..], " \t");
        if (!std.mem.containsAtLeast(u8, command, 1, "obs-autoluanch daemon")) continue;

        try pids.append(gpa, try std.fmt.parseInt(std.process.Child.Id, pid_text, 10));
    }

    return pids.toOwnedSlice(gpa);
}

fn isProcessOpen(gpa: std.mem.Allocator, io: std.Io, process_name: []const u8) !bool {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "pgrep", "-x", process_name },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn isWatchedAppOpen(gpa: std.mem.Allocator, io: std.Io, watch: WatchConfig) !bool {
    if (std.mem.eql(u8, watch.app_source, "display")) {
        return isDisplayAppOpen(gpa, io, watch);
    }

    const process_open = if (std.mem.eql(u8, watch.app_match, "prefix"))
        try isProcessPrefixOpen(gpa, io, watch.app)
    else
        try isProcessOpen(gpa, io, watch.app);

    if (!process_open) return false;
    if (std.mem.eql(u8, watch.app_title_match, "any") or watch.app_title.len == 0) return true;

    return hasMatchingWindowTitle(gpa, io, watch);
}

fn isDisplayAppOpen(gpa: std.mem.Allocator, io: std.Io, watch: WatchConfig) !bool {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);

    try script.appendSlice(gpa,
        \\tell application "System Events"
        \\  repeat with p in application processes
        \\    if background only of p is false then
        \\      set procName to name of p as text
        \\      if 
    );
    if (std.mem.eql(u8, watch.app_match, "prefix")) {
        try script.appendSlice(gpa, "procName starts with ");
    } else {
        try script.appendSlice(gpa, "procName is ");
    }
    try appendAppleScriptString(gpa, &script, watch.app);

    if (std.mem.eql(u8, watch.app_title_match, "any") or watch.app_title.len == 0) {
        try script.appendSlice(gpa,
            \\ then return "true"
            \\    end if
            \\  end repeat
            \\end tell
            \\return "false"
        );
    } else {
        try script.appendSlice(gpa,
            \\ then
            \\        repeat with w in windows of p
            \\          set windowTitle to name of w as text
            \\          if 
        );
        try appendAppleScriptTitlePredicate(gpa, &script, watch);
        try script.appendSlice(gpa,
            \\ then return "true"
            \\        end repeat
            \\      end if
            \\    end if
            \\  end repeat
            \\end tell
            \\return "false"
        );
    }

    const output = try runOsascript(gpa, io, script.items);
    defer gpa.free(output);
    return std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), "true");
}

fn hasMatchingWindowTitle(gpa: std.mem.Allocator, io: std.Io, watch: WatchConfig) !bool {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);

    try script.appendSlice(gpa,
        \\tell application "System Events"
        \\  repeat with p in application processes
        \\    set procName to name of p as text
        \\    if 
    );
    if (std.mem.eql(u8, watch.app_match, "prefix")) {
        try script.appendSlice(gpa, "procName starts with ");
    } else {
        try script.appendSlice(gpa, "procName is ");
    }
    try appendAppleScriptString(gpa, &script, watch.app);
    try script.appendSlice(gpa,
        \\ then
        \\      repeat with w in windows of p
        \\        set windowTitle to name of w as text
        \\        if 
    );
    try appendAppleScriptTitlePredicate(gpa, &script, watch);
    try script.appendSlice(gpa,
        \\ then return "true"
        \\      end repeat
        \\    end if
        \\  end repeat
        \\end tell
        \\return "false"
    );

    const output = try runOsascript(gpa, io, script.items);
    defer gpa.free(output);
    return std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), "true");
}

fn appendAppleScriptTitlePredicate(gpa: std.mem.Allocator, script: *std.ArrayList(u8), watch: WatchConfig) !void {
    if (std.mem.eql(u8, watch.app_title_match, "exact")) {
        try script.appendSlice(gpa, "windowTitle is ");
    } else if (std.mem.eql(u8, watch.app_title_match, "prefix")) {
        try script.appendSlice(gpa, "windowTitle starts with ");
    } else {
        try script.appendSlice(gpa, "windowTitle contains ");
    }
    try appendAppleScriptString(gpa, script, watch.app_title);
}

fn isProcessPrefixOpen(gpa: std.mem.Allocator, io: std.Io, process_prefix: []const u8) !bool {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "ps", "ax", "-o", "comm=" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProcessListFailed,
        else => return error.ProcessListFailed,
    }

    return processListContainsPrefix(result.stdout, process_prefix);
}

fn processListContainsPrefix(output: []const u8, process_prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const basename_start = if (std.mem.lastIndexOfScalar(u8, line, '/')) |slash| slash + 1 else 0;
        const name = line[basename_start..];
        if (std.mem.startsWith(u8, name, process_prefix)) return true;
    }
    return false;
}

fn processExists(gpa: std.mem.Allocator, io: std.Io, pid: std.process.Child.Id) !bool {
    var pid_buffer: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "kill", "-0", pid_text },
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(128),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn launchObs(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: Config,
    watch: WatchConfig,
) !std.process.Child.Id {
    const executable = watch.obs_executable orelse root.obs_executable;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, executable);
    try argv.append(gpa, "--multi");
    try argv.append(gpa, "--scene");
    try argv.append(gpa, watch.scene);
    if (watch.start_recording) try argv.append(gpa, "--startrecording");
    for (watch.obs_args) |arg| try argv.append(gpa, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });

    const pid = child.id.?;
    child.id = null;

    std.debug.print("launched OBS for '{s}' scene '{s}' as pid {d}\n", .{
        watch.name,
        watch.scene,
        pid,
    });

    return pid;
}

fn focusProcess(gpa: std.mem.Allocator, io: std.Io, pid: std.process.Child.Id) !void {
    var script_buffer: [160]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "tell application \"System Events\" to set frontmost of first process whose unix id is {d} to true",
        .{pid},
    );

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "osascript", "-e", script },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
            std.debug.print("failed to focus OBS pid {d}: {s}\n", .{ pid, result.stderr });
            return error.FocusFailed;
        },
        else => return error.FocusFailed,
    }
}

test "parse minimal config" {
    const input =
        \\{
        \\  "configs": [
        \\    {
        \\      "name": "game",
        \\      "app": "Chess",
        \\      "scene": "Chess Capture",
        \\      "start_recording": true
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, input, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 1000), parsed.value.poll_interval_ms);
    try std.testing.expectEqualStrings("Chess", parsed.value.configs[0].app);
    try std.testing.expect(parsed.value.configs[0].start_recording);
}

test "parse per-config obs args" {
    const input =
        \\{
        \\  "poll_interval_ms": 250,
        \\  "obs_executable": "/tmp/OBS",
        \\  "configs": [
        \\    {
        \\      "name": "camera",
        \\      "app": "Photo Booth",
        \\      "scene": "Camera",
        \\      "obs_args": ["--profile", "Camera"]
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, input, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 250), parsed.value.poll_interval_ms);
    try std.testing.expectEqualStrings("--profile", parsed.value.configs[0].obs_args[0]);
}

test "profiles are preferred over legacy configs" {
    const input =
        \\{
        \\  "profiles": [
        \\    {
        \\      "name": "new",
        \\      "app": "Google Chrome",
        \\      "app_match": "prefix",
        \\      "app_title": "Docs",
        \\      "app_title_match": "contains",
        \\      "scene": "Docs"
        \\    }
        \\  ],
        \\  "configs": [
        \\    {
        \\      "name": "old",
        \\      "app": "Chess",
        \\      "scene": "Chess"
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, input, .{});
    defer parsed.deinit();

    const profiles = activeProfiles(parsed.value);
    try std.testing.expectEqual(@as(usize, 1), profiles.len);
    try std.testing.expectEqualStrings("new", profiles[0].name);
    try std.testing.expectEqualStrings("Docs", profiles[0].app_title);
    try std.testing.expectEqualStrings("contains", profiles[0].app_title_match);
}

test "title match labels map to config keys" {
    try std.testing.expectEqualStrings("any", titleMatchKey("Any title"));
    try std.testing.expectEqualStrings("contains", titleMatchKey("Title contains text"));
    try std.testing.expectEqualStrings("exact", titleMatchKey("Exact title"));
    try std.testing.expectEqualStrings("prefix", titleMatchKey("Title starts with text"));
}

test "parse daemon pids from ps output" {
    const output =
        \\  101 /usr/bin/login
        \\  202 /opt/homebrew/bin/obs-autoluanch daemon /opt/homebrew/etc/obs-autoluanch/config.json
        \\  303 /opt/homebrew/bin/obs-autoluanch status
        \\  404 /tmp/obs-autoluanch daemon /tmp/other.json
        \\
    ;

    const pids = try parseDaemonPids(std.testing.allocator, output);
    defer std.testing.allocator.free(pids);

    try std.testing.expectEqual(@as(usize, 2), pids.len);
    try std.testing.expectEqual(@as(std.process.Child.Id, 202), pids[0]);
    try std.testing.expectEqual(@as(std.process.Child.Id, 404), pids[1]);
}

test "first words for prefix app matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("Google Chrome", try firstWords(arena.allocator(), "Google Chrome Canary", 2));
    try std.testing.expectEqualStrings("OBS", try firstWords(arena.allocator(), "OBS", 2));
}

test "process prefix matching" {
    const output =
        \\/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary
        \\/Applications/Slack.app/Contents/MacOS/Slack
        \\
    ;

    try std.testing.expect(processListContainsPrefix(output, "Google Chrome"));
    try std.testing.expect(!processListContainsPrefix(output, "Google Drive"));
}

test "default config path resolves under home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/tester");

    try std.testing.expectEqualStrings(
        "/Users/tester/.config/obsautolaunch/config.json",
        try resolveConfigPath(arena.allocator(), &env, null),
    );
    try std.testing.expectEqualStrings(
        "custom.json",
        try resolveConfigPath(arena.allocator(), &env, "custom.json"),
    );
}
