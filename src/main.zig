// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2022 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

const usage_message =
    \\Until - Keep track of important milestones from the terminal
    \\usage:
    \\  unt <command>
    \\  commands:
    \\    add  <event_name> <date>
    \\    rm   <event_id>
    \\    list
    \\    reset (delete save file)
    \\
;

const save_filename = "savefile.json";
const max_savefile_size = 1024 * 1024;

const JsonEntry = struct {
    name: []const u8,
    date: []const u8,
};

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const allocator = general_purpose_allocator.allocator();
    defer _ = general_purpose_allocator.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer _ = arena_instance.deinit();

    const arena = arena_instance.allocator();
    const args = try std.process.argsAlloc(arena);

    if (args.len < 2) {
        std.debug.print(usage_message, .{});
        return;
    }

    const matches = std.mem.startsWith;
    const command = args[1];

    if (matches(u8, command, "add")) {
        if (args.len != 4) {
            std.log.err("Invalid command arguments", .{});
            std.debug.print(usage_message, .{});
            return;
        }
        const event_name = args[2];
        const date_string = args[3];
        try commandAdd(allocator, event_name, date_string);
    } else if (matches(u8, command, "rm")) {
        commandRemove(args[2]);
    } else if (matches(u8, command, "list")) {
        commandList(allocator) catch |err| {
            std.log.err("Failed to list events. Error: {}", .{err});
            return;
        };
    } else if (matches(u8, command, "reset")) {
        try commandReset(allocator);
    } else {
        std.log.err("Invalid command argument: {s}", .{args[0]});
    }
}

fn commandAdd(allocator: std.mem.Allocator, name: []const u8, date: []const u8) !void {
    const new_event_timestamp = try parseDateString(date);

    const app_dir = try std.fs.getAppDataDir(allocator, "until");
    defer allocator.free(app_dir);
    std.fs.makeDirAbsolute(app_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    var skip_json_load: bool = false;

    const savefile_path = try std.mem.join(allocator, "/", &[_][]const u8{ app_dir, save_filename });
    defer allocator.free(savefile_path);
    var savefile = blk: {
        const existing_file = std.fs.openFileAbsolute(savefile_path, .{ .mode = .read_write }) catch |open_err| {
            if (open_err != error.FileNotFound) {
                return open_err;
            }
            std.log.info("No savefile found, creating now: '{s}'", .{savefile_path});
            skip_json_load = true;
            const new_file = std.fs.createFileAbsolute(savefile_path, .{ .truncate = true, .read = true }) catch |create_err| {
                std.log.err("Failed to create new savefile at '{s}'. Error: {}", .{ savefile_path, create_err });
                return create_err;
            };
            break :blk new_file;
        };
        break :blk existing_file;
    };
    defer savefile.close();

    if (skip_json_load) {
        const json_entry = JsonEntry{
            .name = name,
            .date = date,
        };
        const json_array = [1]JsonEntry{json_entry};
        try std.json.stringify(json_array, .{}, savefile.writer());
        return;
    }

    //
    // Load existing json into memory, append new event, rewrite back to file
    //

    const json_string = try savefile.readToEndAlloc(allocator, max_savefile_size);
    defer allocator.free(json_string);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    var json_root = try parser.parse(json_string);
    defer json_root.deinit();

    // Set file size to 0
    try savefile.seekTo(0);
    try savefile.setEndPos(0);

    if (json_root.root.Array.items.len == 0) {
        const json_entry = JsonEntry{
            .name = name,
            .date = date,
        };
        const json_array = [1]JsonEntry{json_entry};
        try std.json.stringify(json_array, .{}, savefile.writer());
        return;
    }

    var entries = try allocator.alloc(JsonEntry, json_root.root.Array.items.len + 1);
    defer allocator.free(entries);

    var timestamps = try allocator.alloc(i64, json_root.root.Array.items.len + 1);
    defer allocator.free(timestamps);

    std.debug.assert(entries.len == timestamps.len);

    for (json_root.root.Array.items) |event, event_i| {
        var it = event.Object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "date")) {
                entries[event_i].date = entry.value_ptr.*.String;
                timestamps[event_i] = try parseDateString(entry.value_ptr.*.String);
                continue;
            }
            if (std.mem.eql(u8, entry.key_ptr.*, "name")) {
                entries[event_i].name = entry.value_ptr.*.String;
                continue;
            }
        }
    }

    entries[entries.len - 1] = JsonEntry{ .name = name, .date = date };
    timestamps[entries.len - 1] = new_event_timestamp;

    //
    // Sort by timestamp
    //

    {
        const entry_count: usize = entries.len;
        var step: usize = 1;
        while (step < entry_count) : (step += 1) {
            const key = timestamps[step];
            const entry_key = entries[step];
            var x = @intCast(i64, step) - 1;
            while (x >= 0 and timestamps[@intCast(usize, x)] > key) : (x -= 1) {
                timestamps[@intCast(usize, x) + 1] = timestamps[@intCast(usize, x)];
                entries[@intCast(usize, x) + 1] = entries[@intCast(usize, x)];
            }
            timestamps[@intCast(usize, x + 1)] = key;
            entries[@intCast(usize, x + 1)] = entry_key;
        }
    }

    try std.json.stringify(entries, .{}, savefile.writer());
}

// TODO: Implement
fn commandRemove(name: []const u8) void {
    std.log.info("Removing event: {s}", .{name});
}

fn commandReset(allocator: std.mem.Allocator) !void {
    const app_dir = try std.fs.getAppDataDir(allocator, "until");
    defer allocator.free(app_dir);
    std.log.info("Removing app directory: {s}", .{app_dir});
    std.fs.deleteTreeAbsolute(app_dir) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };
}

fn commandList(allocator: std.mem.Allocator) !void {
    const savefile_path: []const u8 = try savefilePath(allocator);
    defer allocator.free(savefile_path);

    const savefile = std.fs.openFileAbsolute(savefile_path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };
    defer savefile.close();

    const json_string = try savefile.readToEndAlloc(allocator, max_savefile_size);
    defer allocator.free(json_string);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    var json_root = try parser.parse(json_string);
    defer json_root.deinit();

    if (json_root.root.Array.items.len <= 0) {
        return error.InvalidSavefile;
    }

    const current_time = std.time.timestamp();
    for (json_root.root.Array.items) |event, event_i| {
        var it = event.Object.iterator();
        var duration_days: u32 = 0;
        var is_past: bool = false;
        var event_name: []const u8 = undefined;
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "date")) {
                const event_timestamp = try parseDateString(entry.value_ptr.*.String);
                is_past = (current_time > event_timestamp);
                const time_until = if (is_past) current_time - event_timestamp else event_timestamp - current_time;
                duration_days = @divTrunc(@intCast(u32, time_until), std.time.s_per_day);
                continue;
            }
            if (std.mem.eql(u8, entry.key_ptr.*, "name")) {
                event_name = entry.value_ptr.*.String;
                continue;
            }
        }
        std.debug.print("  {d:.2}. {d} days {s} {s}\n", .{ event_i + 1, duration_days, if (is_past) "since" else "until", event_name });
    }
}

/// Returns the absolute path for the json save file
fn savefilePath(allocator: std.mem.Allocator) ![]const u8 {
    const path = try std.fs.getAppDataDir(allocator, "until");
    defer allocator.free(path);
    return try std.mem.join(allocator, "/", &[_][]const u8{ path, save_filename });
}

/// Expected format dd/mm/yyyy
fn parseDateString(date: []const u8) !i64 {
    if (date[2] != '/' or date[5] != '/') {
        return error.InvalidDateStringFormat;
    }

    const isDigit = std.ascii.isDigit;
    if (!isDigit(date[0]) or !isDigit(date[1]) or !isDigit(date[3]) or !isDigit(date[4]) or !isDigit(date[6])) {
        return error.InvalidDateStringFormat;
    }

    const day: u32 = ((date[0] - '0') * 10) + date[1] - '0';
    const month: u32 = ((date[3] - '0') * 10) + date[4] - '0';
    const year: u32 = (@intCast(u32, date[6] - '0') * 1000) + @intCast(u32, date[7] - '0') * 100 + ((date[8] - '0') * 10) + (date[9] - '0');

    var time: c.tm = undefined;
    time.tm_year = @intCast(c_int, year - 1900);
    time.tm_mon = @intCast(c_int, month - 1);
    time.tm_mday = @intCast(c_int, day);
    time.tm_hour = 0;
    time.tm_min = 0;
    time.tm_sec = 0;

    const timestamp = c.timegm(&time);

    if (timestamp == -1) {
        return error.Unknown;
    }

    return timestamp;
}
