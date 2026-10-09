//! Owned copy of an OSC 7501 report for the embedder action callback.
//!
//! The parser's strings point into its buffer and die when the next
//! sequence is read. The surface mailbox is asynchronous, so the IO
//! thread copies the report into this allocation before queueing it.
//! The host sees `report` only during the action callback.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("../lib/main.zig");
const terminal = @import("../terminal/main.zig");
const osc_program_status = @import("../terminal/osc/parsers/program_status.zig");

/// What the program is doing. Integer values match
/// `GhosttyProgramStatusState` in `include/ghostty/vt/terminal.h`.
pub const State = enum(c_int) {
    idle = 0,
    working = 1,
    done = 2,
    blocked = 3,
    @"error" = 4,
    clear = 5,

    test "ghostty.h program status state" {
        try lib.checkGhosttyHEnum(State, "GHOSTTY_ACTION_PROGRAM_STATUS_STATE_");
    }
};

/// What a blocked program needs. Integer values match
/// `GhosttyProgramStatusKind`, including `none` at zero.
pub const Kind = enum(c_int) {
    none = 0,
    permission = 1,
    question = 2,
    auth = 3,

    test "ghostty.h program status kind" {
        try lib.checkGhosttyHEnum(Kind, "GHOSTTY_ACTION_PROGRAM_STATUS_KIND_");
    }
};

/// Layout-compatible with `GhosttyTerminalProgramStatus`.
///
/// C type: ghostty_action_program_status_s
pub const Report = extern struct {
    size: usize,
    state: State,
    kind: Kind,
    progress: i8,
    id: lib.String,
    app: lib.String,
    title: lib.String,
    message: lib.String,

    /// Borrow parser fields and decode text into caller-owned scratch space.
    pub fn init(
        parsed: osc_program_status.Report,
        title_buf: *[osc_program_status.max_title_bytes]u8,
        message_buf: *[osc_program_status.max_msg_bytes]u8,
    ) Report {
        var title_writer: std.Io.Writer = .fixed(title_buf);
        parsed.writeText(.title, &title_writer) catch unreachable;
        var message_writer: std.Io.Writer = .fixed(message_buf);
        parsed.writeText(.msg, &message_writer) catch unreachable;
        return .{
            .size = @sizeOf(Report),
            .state = @enumFromInt(@intFromEnum(parsed.state)),
            .kind = if (parsed.readOption(.kind)) |kind| switch (kind) {
                .permission => .permission,
                .question => .question,
                .auth => .auth,
            } else .none,
            .progress = if (parsed.readOption(.progress)) |value| @intCast(value) else -1,
            .id = .init(parsed.readOption(.id) orelse ""),
            .app = .init(parsed.readOption(.app) orelse ""),
            .title = .init(title_writer.buffered()),
            .message = .init(message_writer.buffered()),
        };
    }
};

pub const Event = enum(c_int) {
    report = 0,
    prompt = 1,
    reset = 2,
};

/// Optional IO-thread ingress. No report allocation or UI mailbox is needed.
/// The callback must copy borrowed fields, remain bounded and never call
/// Ghostty APIs or UI APIs. Userdata remains alive until surface IO joins.
pub const Ingress = struct {
    callback: *const fn (?*anyopaque, ?*anyopaque, Event, ?*const Report) callconv(.c) void,
    app_userdata: ?*anyopaque,
    surface_userdata: ?*anyopaque,

    pub fn emit(self: Ingress, event: Event, report: ?*const Report) void {
        self.callback(self.app_userdata, self.surface_userdata, event, report);
    }

    pub fn emitReport(self: Ingress, parsed: osc_program_status.Report) void {
        var title: [osc_program_status.max_title_bytes]u8 = undefined;
        var message: [osc_program_status.max_msg_bytes]u8 = undefined;
        const borrowed = Report.init(parsed, &title, &message);
        self.emit(.report, &borrowed);
    }
};

/// Action payload. The C value is a pointer valid only during the callback.
/// A pointer keeps `ghostty_action_u` at 24 bytes.
pub const ActionValue = struct {
    report: *const Report,

    pub const C = *const Report;

    pub fn cval(self: ActionValue) C {
        return self.report;
    }
};

/// Heap copy of a report. `deinit` frees the strings and this struct.
pub const Owned = struct {
    alloc: Allocator,
    bytes: []u8,
    surface_id: u64,
    report: Report,

    pub fn create(
        alloc: Allocator,
        report: osc_program_status.Report,
        surface_id: u64,
    ) Allocator.Error!*Owned {
        var title_buf: [osc_program_status.max_title_bytes]u8 = undefined;
        var title_writer: std.Io.Writer = .fixed(&title_buf);
        report.writeText(.title, &title_writer) catch unreachable;
        const title = title_writer.buffered();

        var message_buf: [osc_program_status.max_msg_bytes]u8 = undefined;
        var message_writer: std.Io.Writer = .fixed(&message_buf);
        report.writeText(.msg, &message_writer) catch unreachable;
        const message = message_writer.buffered();

        const id = report.readOption(.id) orelse "";
        const app = report.readOption(.app) orelse "";
        const total = id.len + app.len + title.len + message.len;

        const owned = try alloc.create(Owned);
        errdefer alloc.destroy(owned);
        const bytes = try alloc.alloc(u8, total);
        errdefer alloc.free(bytes);

        var offset: usize = 0;
        const id_s = copyInto(bytes, &offset, id);
        const app_s = copyInto(bytes, &offset, app);
        const title_s = copyInto(bytes, &offset, title);
        const message_s = copyInto(bytes, &offset, message);
        std.debug.assert(offset == bytes.len);

        owned.* = .{
            .alloc = alloc,
            .bytes = bytes,
            .surface_id = surface_id,
            .report = .{
                .size = @sizeOf(Report),
                .state = @enumFromInt(@intFromEnum(report.state)),
                .kind = if (report.readOption(.kind)) |kind| switch (kind) {
                    .permission => .permission,
                    .question => .question,
                    .auth => .auth,
                } else .none,
                .progress = if (report.readOption(.progress)) |value|
                    @intCast(value)
                else
                    -1,
                .id = id_s,
                .app = app_s,
                .title = title_s,
                .message = message_s,
            },
        };
        return owned;
    }

    pub fn deinit(self: *Owned) void {
        self.alloc.free(self.bytes);
        self.alloc.destroy(self);
    }
};

/// Reply to `OSC 7501 ; ?`, using the request's terminator.
pub fn queryReply(terminator: terminal.osc.Terminator) []const u8 {
    return switch (terminator) {
        .st => "\x1b]7501;?\x1b\\",
        .bel => "\x1b]7501;?\x07",
    };
}

fn copyInto(bytes: []u8, offset: *usize, text: []const u8) lib.String {
    if (text.len == 0) return .init(@as([]const u8, ""));
    const dest = bytes[offset.*..][0..text.len];
    @memcpy(dest, text);
    offset.* += text.len;
    return .init(dest);
}

fn parseOwned(alloc: Allocator, body: []const u8) !*Owned {
    var p: terminal.osc.Parser = .init(alloc);
    defer p.deinit();
    p.nextSlice(body);
    // Copy before the parser buffer is freed.
    return try Owned.create(alloc, p.end('\x1b').?.program_status.report, 42);
}

test "program status report matches libghostty-vt field order" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(usize), @offsetOf(Report, "state"));
    try testing.expectEqual(@sizeOf(usize) + @sizeOf(c_int), @offsetOf(Report, "kind"));
    try testing.expectEqual(
        @sizeOf(usize) + 2 * @sizeOf(c_int),
        @offsetOf(Report, "progress"),
    );
    const strings_at = std.mem.alignForward(
        usize,
        @sizeOf(usize) + 2 * @sizeOf(c_int) + @sizeOf(i8),
        @alignOf(lib.String),
    );
    try testing.expectEqual(strings_at, @offsetOf(Report, "id"));
    try testing.expectEqual(strings_at + @sizeOf(lib.String), @offsetOf(Report, "app"));
    try testing.expectEqual(strings_at + 2 * @sizeOf(lib.String), @offsetOf(Report, "title"));
    try testing.expectEqual(strings_at + 3 * @sizeOf(lib.String), @offsetOf(Report, "message"));
    try testing.expectEqual(strings_at + 4 * @sizeOf(lib.String), @sizeOf(Report));
}

test "program status copy outlives the parser buffer" {
    const testing = std.testing;
    var p: terminal.osc.Parser = .init(testing.allocator);
    defer p.deinit();

    // "Plan" and "Apply?"
    var chunks = std.mem.window(
        u8,
        "7501;state=working:id=build/test:app=cargo:progress=40:title=UGxhbg==:msg=QXBwbHk/",
        7,
        7,
    );
    while (chunks.next()) |chunk| p.nextSlice(chunk);
    const parsed = p.end('\x1b').?.program_status.report;
    const owned = try Owned.create(testing.allocator, parsed, 42);
    defer owned.deinit();

    p.reset();
    p.nextSlice("7501;state=idle");
    _ = p.end('\x1b');

    try testing.expectEqual(State.working, owned.report.state);
    try testing.expectEqual(Kind.none, owned.report.kind);
    try testing.expectEqual(@as(i8, 40), owned.report.progress);
    try testing.expectEqual(@sizeOf(Report), owned.report.size);
    try testing.expectEqualStrings("build/test", owned.report.id.ptr[0..owned.report.id.len]);
    try testing.expectEqualStrings("cargo", owned.report.app.ptr[0..owned.report.app.len]);
    try testing.expectEqualStrings("Plan", owned.report.title.ptr[0..owned.report.title.len]);
    try testing.expectEqualStrings("Apply?", owned.report.message.ptr[0..owned.report.message.len]);
}

test "program status kind and progress follow the state" {
    const testing = std.testing;

    const blocked_owned = try parseOwned(
        testing.allocator,
        "7501;state=blocked:kind=permission:progress=7:app=terraform",
    );
    defer blocked_owned.deinit();
    try testing.expectEqual(State.blocked, blocked_owned.report.state);
    try testing.expectEqual(Kind.permission, blocked_owned.report.kind);
    try testing.expectEqual(@as(i8, 7), blocked_owned.report.progress);
    try testing.expectEqual(@as(usize, 0), blocked_owned.report.id.len);
    try testing.expectEqual(@as([*]const u8, ""), blocked_owned.report.id.ptr);
    try testing.expectEqualStrings(
        "terraform",
        blocked_owned.report.app.ptr[0..blocked_owned.report.app.len],
    );

    const done_owned = try parseOwned(testing.allocator, "7501;state=done:kind=auth:progress=40");
    defer done_owned.deinit();
    try testing.expectEqual(State.done, done_owned.report.state);
    try testing.expectEqual(Kind.none, done_owned.report.kind);
    try testing.expectEqual(@as(i8, -1), done_owned.report.progress);

    const clear_owned = try parseOwned(testing.allocator, "7501;state=clear:id=build");
    defer clear_owned.deinit();
    try testing.expectEqual(State.clear, clear_owned.report.state);
    try testing.expectEqualStrings("build", clear_owned.report.id.ptr[0..clear_owned.report.id.len]);
}

test "program status query reply uses the request terminator" {
    const testing = std.testing;
    try testing.expectEqualStrings("\x1b]7501;?\x1b\\", queryReply(.st));
    try testing.expectEqualStrings("\x1b]7501;?\x07", queryReply(.bel));
}

test "program status rejects closed or replaced surface and frees reports" {
    const testing = std.testing;
    const Message = @import("surface.zig").Message;
    const closed = try parseOwned(testing.allocator, "7501;state=done:msg=RG9uZQ==");
    try testing.expect(!(Message{ .program_status = closed }).acceptProgramStatus(null));
    const replaced = try parseOwned(testing.allocator, "7501;state=working");
    try testing.expect(!(Message{ .program_status = replaced }).acceptProgramStatus(43));
    const live = try parseOwned(testing.allocator, "7501;state=done");
    defer live.deinit();
    try testing.expect((Message{ .program_status = live }).acceptProgramStatus(42));
    try testing.expect(!(Message{ .shell_prompt = 42 }).acceptProgramStatus(43));
    try testing.expect(!(Message{ .full_reset = 42 }).acceptProgramStatus(null));
    try testing.expect((Message{ .full_reset = 42 }).acceptProgramStatus(42));
}

test "program status synchronous ingress preserves burst and lifecycle order" {
    const testing = std.testing;
    const Probe = struct {
        count: usize = 0,
        last: State = .idle,
        lifecycle: [2]Event = undefined,
        lifecycle_count: usize = 0,

        fn receive(_: ?*anyopaque, userdata: ?*anyopaque, event: Event, report: ?*const Report) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (event == .report) {
                self.count += 1;
                self.last = report.?.state;
            } else {
                std.debug.assert(report == null);
                self.lifecycle[self.lifecycle_count] = event;
                self.lifecycle_count += 1;
            }
        }
    };
    var probe: Probe = .{};
    const ingress: Ingress = .{
        .callback = Probe.receive,
        .app_userdata = null,
        .surface_userdata = &probe,
    };
    var parser: terminal.osc.Parser = .init(testing.allocator);
    defer parser.deinit();
    parser.nextSlice("7501;state=working:id=build:msg=SGVsbG8=");
    const report = parser.end('\x1b').?.program_status.report;
    for (0..4096) |_| ingress.emitReport(report);
    parser.reset();
    parser.nextSlice("7501;state=clear");
    ingress.emitReport(parser.end('\x1b').?.program_status.report);
    ingress.emit(.prompt, null);
    ingress.emit(.reset, null);
    try testing.expectEqual(@as(usize, 4097), probe.count);
    try testing.expectEqual(State.clear, probe.last);
    try testing.expectEqualSlices(Event, &.{ .prompt, .reset }, &probe.lifecycle);
}
