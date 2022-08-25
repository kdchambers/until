const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

const usage_message =
    \\usage:
    \\  until <command>
    \\  commands:
    \\    add  <event_name> [<description>] <date>
    \\    rm   <event_id>
    \\    list
    \\    reset (delete save file)
    \\
;

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
    const timestamp = try parseDateString(date);
    const savefile_path = try std.fs.getAppDataDir(allocator, "until");
    defer allocator.free(savefile_path);
    var save_file = blk: {
        const existing_file = std.fs.openFileAbsolute(savefile_path, .{ .mode = .write_only }) catch |open_err| {
            if (open_err != error.FileNotFound) {
                return open_err;
            }
            std.log.info("No savefile found. Creating..", .{});
            const new_file = std.fs.createFileAbsolute(savefile_path, .{ .truncate = true, .read = true }) catch |create_err| {
                std.log.err("Failed to create new savefile at '{s}'. Error: {}", .{ savefile_path, create_err });
                return create_err;
            };
            break :blk new_file;
        };
        break :blk existing_file;
    };
    defer save_file.close();

    // Seek to end so that we append new data
    const end_position = try save_file.getEndPos();
    try save_file.seekTo(end_position);

    const writer = save_file.writer();
    try writer.writeIntLittle(i64, timestamp);
    try writer.writeIntLittle(u32, @intCast(u32, name.len));
    try writer.writeIntLittle(u32, 0);
    try writer.writeAll(name);
    std.log.info("{s} successfully added", .{name});
}

fn commandRemove(name: []const u8) void {
    std.log.info("Removing event: {s}", .{name});
}

fn commandReset(allocator: std.mem.Allocator) !void {
    const savefile_path: []const u8 = try std.fs.getAppDataDir(allocator, "until");
    defer allocator.free(savefile_path);
    std.log.info("Removing file: {s}", .{savefile_path});
    try std.fs.deleteFileAbsolute(savefile_path);
}

fn commandList(allocator: std.mem.Allocator) !void {
    const savefile_path: []const u8 = try std.fs.getAppDataDir(allocator, "until");
    defer allocator.free(savefile_path);
    const savefile = std.fs.openFileAbsolute(savefile_path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };
    defer savefile.close();
    const reader = savefile.reader();
    var i: usize = 0;
    var name_buffer: [256]u8 = undefined;
    while (i < 100) : (i += 1) {
        const timestamp = reader.readIntLittle(i64) catch |err| {
            if (err == error.EndOfStream) {
                return;
            }
            return err;
        };
        const name_length = try reader.readIntLittle(u32);
        try reader.skipBytes(@sizeOf(u32), .{});
        if (try reader.read(name_buffer[0..name_length]) < name_length) {
            std.log.err("Failed to read entire event name. Savefile is corrupted", .{});
            return error.SavefileCorrupted;
        }
        const name: []const u8 = name_buffer[0..name_length];
        std.debug.print("  {d:.2}. {s} at {d}\n", .{ i + 1, name, timestamp });
    }
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

    std.debug.print("Date: {d}/{d}/{d}\n", .{ day, month, year });

    var time: c.tm = undefined;
    time.tm_year = @intCast(c_int, year - 1900);
    time.tm_mon = @intCast(c_int, month - 1);
    time.tm_mday = @intCast(c_int, day - 1);
    time.tm_hour = 0;
    time.tm_min = 0;
    time.tm_sec = 0;

    const timestamp = c.timegm(&time);
    return timestamp;
}
