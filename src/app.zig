const std = @import("std");
const vaxis = @import("vaxis");
const utils = @import("utils.zig");
const Cell = vaxis.Cell;
const StatusLine = @import("status_line.zig").StatusLine;
const Comps = @import("components.zig");

const CharType: type = u8;
const GapBuffer = @import("gap_buffer.zig").GapBuffer(CharType);

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.main);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const CursorState = struct {
    row: u16 = 0,
    col: u16 = 0,
};

pub const Mode = enum {
    Normal,
    Insert,
};

pub const App = struct {
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,

    allocator: Allocator,

    file: std.fs.File = undefined,

    buff: GapBuffer,

    input_queue: std.ArrayList(u21),

    top: usize,
    left: usize,

    text_buffer: []CharType,
    mode: Mode,

    need_realloc: bool,

    quit: bool,
    cursor: CursorState,

    statusLine: StatusLine,

    editor: struct {
        fg: vaxis.Color = .{
            .rgb = .{ 87, 82, 121 },
        },

        win_opts: vaxis.Window.ChildOptions = .{},
    },

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const Self = @This();

    fn init() !Self {
        var allocator = App.gpa.allocator();
        return Self{
            .allocator = allocator,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .quit = false,
            .cursor = .{},
            .buff = try GapBuffer.init(allocator),
            .mode = Mode.Normal,
            .top = 0,
            .editor = .{},
            .input_queue = std.ArrayList(u21).init(allocator),
            .need_realloc = false,
            .text_buffer = try allocator.alloc(CharType, 0),
            .statusLine = StatusLine.init(allocator),
            .left = 0,
        };
    }

    pub var instance: ?Self = null;
    pub fn getInstance() !*Self {
        if (App.instance) |*app| {
            return app;
        }

        App.instance = try App.init();
        return &App.instance.?;
    }

    pub fn deinit(self: *Self) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
        self.buff.deinit();
        self.allocator.free(self.text_buffer);

        self.input_queue.deinit();
        self.statusLine.deinit();

        const deinit_status = App.gpa.deinit();
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }

    fn getBuff(self: *Self) ![]CharType {
        if (self.need_realloc) {
            const buffers = self.buff.getBuffers();

            var buff = try self.allocator.alloc(CharType, buffers[0].len + buffers[1].len);

            for (0..buffers[0].len) |i| {
                buff[i] = buffers[0][i];
            }

            for (buffers[0].len..buffers[0].len + buffers[1].len, 0..buffers[1].len) |i, j| {
                buff[i] = buffers[1][j];
            }

            self.allocator.free(self.text_buffer);
            self.text_buffer = buff;
        }

        self.need_realloc = false;
        return self.text_buffer;
    }

    fn updateDims(self: *Self) !void {
        const win = self.vx.window();
        self.editor.win_opts = .{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = win.height - 2,
        };

         self.statusLine.win_opts = .{
            .x_off = 0,
            .y_off = win.height - 2,
            .height = 1,
            .width = win.width,
        };
    }

    fn checkBounds(self: *Self) void {
        if (self.cursor.row >= self.editor.win_opts.height.? - 1) {
            self.top += 1;
            self.cursor.row -|= 1;
        } else if (self.cursor.row == 0 and self.top > 0) {
            self.top -= 1;
            self.cursor.row +|= 1;
        }

        if (self.cursor.col >= self.editor.win_opts.width.? - 1) {
            self.left += 1;
            self.cursor.col -|= 1;
        } else if (self.cursor.col == 0 and self.left > 0) {
            self.left -= 1;
            self.cursor.col +|= 1;
        }
    }

    fn moveAbs(self: *Self, col: u16, row: u16) !void {
        self.cursor.row = row;
        self.cursor.col = col;
        self.checkBounds();
    }

    fn moveUp(self: *Self, steps: u16) void {
        self.cursor.row -|= steps;
        self.checkBounds();
    }

    fn moveDown(self: *Self, steps: u16) void {
        self.cursor.row +|= steps;
        self.checkBounds();
    }

    fn moveLeft(self: *Self, steps: u16) void {
        self.cursor.col -|= steps;
        self.checkBounds();
    }

    fn moveRight(self: *Self, steps: u16) void {
        self.cursor.col +|= steps;
        self.checkBounds();
    }

    fn update(self: *Self) !void {
        try self.updateDims();

        const editorHeight = self.editor.win_opts.height.?;

        var splits = std.mem.split(CharType, try self.getBuff(), "\n");

        var row: usize = 0;
        var idx: usize = 0; // Current Cell
        var virt_row: u16 = 0;

        // we are here
        //
        // State Update

        while (splits.next()) |chunk| : (row +|= 1) {
            if (row < self.top) {
                idx += @intCast(chunk.len + 1);
                continue;
            }

            if (row > self.top + editorHeight) {
                break;
            }

            if (chunk.len == 0) {
                if (self.cursor.row == virt_row) {
                    try self.buff.moveGap(idx);
                    self.cursor.col = 0;
                }
            }

            var virt_col: u16 = 0;
            for (0..chunk.len) |col| {
                if (self.left > col) {
                    idx += 1;
                    continue;
                }

                if (virt_row == self.cursor.row) {
                    if (self.mode == Mode.Normal) {
                        self.cursor.col = @min(chunk.len - 1 -| self.left, self.cursor.col);
                    }

                    if (self.cursor.col == virt_col) {
                        try self.buff.moveGap(idx);
                    }
                }
                idx += 1;

                // Solves the case where we press 'a' and the cursor is at the last
                // element in the row
                if (self.cursor.row == virt_row and self.cursor.col == chunk.len - 1 -| self.left) {
                    try self.buff.moveGap(idx);
                }
                virt_col += 1;
            }

            virt_row += 1;
            // skip '\n'
            idx += 1;
        }

        // because of the last + 1 of the while.
        self.cursor.row = @min(virt_row -| 2, self.cursor.row);
        self.top = @min(self.top, row -| 2);
    }

    fn drawEditor(self: *Self, editorWin: *vaxis.Window) !void {
        var splits = std.mem.split(CharType, try self.getBuff(), "\n");

        var row: usize = 0;
        var virt_row: u16 = 0;

        while (splits.next()) |chunk| : (row +|= 1) {
            if (row < self.top) {
                continue;
            }

            if (row > self.top + editorWin.height) {
                break;
            }

            var virt_col: u16 = 0;
            for (0..chunk.len) |col| {
                if (col < self.left) {
                    continue;
                }

                editorWin.writeCell(virt_col, virt_row, Cell{ .char = .{
                    .grapheme = chunk[col .. col + 1],
                }, .style = .{ .fg = self.editor.fg } });
                virt_col += 1;
            }

            virt_row += 1;
        }

        editorWin.showCursor(self.cursor.col, self.cursor.row);
    }

    fn draw(self: *Self) !void {
        const win = self.vx.window();

        win.clear();

        var statusLineWin = win.child(self.statusLine.win_opts);
        var editorWin = win.child(self.editor.win_opts);

        try self.statusLine.draw(&statusLineWin);
        try self.drawEditor(&editorWin);

        try self.vx.render(self.tty.anyWriter());
    }

    fn handleNormalMode(self: *Self, key: vaxis.Key) !void {
        // Needs much more work, will stay like that just for testing.
        //

        var delimtersSet = try utils.getDelimterSet(self.allocator);
        defer delimtersSet.deinit();

        if (key.matches('l', .{})) {
            self.moveRight(1);
        } else if (key.matches('j', .{})) {
            self.moveDown(1);
        } else if (key.matches('h', .{})) {
            self.moveLeft(1);
        } else if (key.matches('k', .{})) {
            self.moveUp(1);
        } else if (key.matches('q', .{})) {
            self.quit = true;
        } else if (key.matches('i', .{})) {
            self.mode = Mode.Insert;
        } else if (key.matches('a', .{})) {
            self.mode = Mode.Insert;
            self.moveRight(1);
        } else if (key.matches('d', .{ .ctrl = true })) {
            self.top +|= self.vx.window().height / 2;
        } else if (key.matches('u', .{ .ctrl = true })) {
            self.top -|= self.vx.window().height / 2;
        } else if (key.matches('x', .{})) {
            try self.buff.deleteForwards(GapBuffer.SearchPolicy{ .Number = 1 }, false);
        } else {
            try self.input_queue.append(key.codepoint);
        }
    }
    fn handleInsertMode(self: *Self, key: vaxis.Key) !void {
        self.need_realloc = true;
        if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
            self.mode = Mode.Normal;
            self.moveLeft(1);
        } else if (key.matches(vaxis.Key.enter, .{})) {
            try self.buff.write("\n");
            self.moveDown(1);
            self.cursor.col = 0;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.cursor.col == 0) {
                self.moveUp(1);
                // Go to the end of the last line
            } else {
                self.moveLeft(1);
            }
            try self.buff.deleteBackwards(GapBuffer.SearchPolicy{ .Number = 1 }, true);
        } else if (key.text) |text| {
            try self.buff.write(text);
            self.moveRight(1);
        }
    }

    fn handleEvent(self: *Self, event: Event) !void {
        switch (event) {
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
            },
            .key_press => |key| {
                switch (self.mode) {
                    .Normal => try self.handleNormalMode(key),
                    .Insert => try self.handleInsertMode(key),
                }
            },
        }
    }

    fn readFile(self: *Self) !void {
        var args = std.process.args();

        _ = args.next().?;

        var file_name: []const u8 = "";
        if (args.next()) |arg| {
            file_name = arg;
        } else {
            log.err("Must provide a file", .{});
        }

        self.file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
            log.err("Could not open the file", .{});
            return err;
        };
        const file_size = (try self.file.stat()).size;
        const file_contents = try self.file.readToEndAlloc(self.allocator, file_size);
        defer self.allocator.free(file_contents);

        try self.buff.write(file_contents);
        try self.buff.moveGap(0);
        self.need_realloc = true;
    }

    pub fn run(self: *Self) !void {
        try self.readFile();

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        // Loop Setup
        try loop.init();
        try loop.start();

        defer loop.stop();

        // Settings
        try self.vx.enterAltScreen(self.tty.anyWriter());
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

        try Comps.addComps();

        while (!self.quit) {
            loop.pollEvent();

            // If there is some event, then handle it
            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            try self.update();

            try self.draw();
        }
    }
};
