const std = @import("std");
const net = std.net;

const ConnError = error{
    NotFound,
};

const HeaderType = union(enum) {
    Host: []const u8,
    UserAgent: []const u8,
    Accept: []const u8,
};

const buf_len = 1024;

const Response = struct {
    buf: [buf_len:0]u8,
    content_type: []const u8,
};

const thread_num = 8;

var directory: ?[]const u8 = undefined;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Logs from your program will appear here!\n", .{});

    var args = std.process.args();

    _ = args.next().?;
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--directory")) {
            directory = args.next().?;
        }
    }

    const address = try net.Address.resolveIp("127.0.0.1", 4221);

    var thread_pool: [thread_num]std.Thread = undefined;

    for (0..thread_num) |i| {
        thread_pool[i] = try std.Thread.spawn(.{}, handle_connection, .{address});
    }

    while (true) {}
}

fn handle_connection(address: std.net.Address) !void {
    const stdout = std.io.getStdOut().writer();
    while (true) {
        var listener = try address.listen(.{
            .reuse_address = true,
        });
        defer listener.deinit();

        const connection = try listener.accept();
        defer connection.stream.close();

        try stdout.print("accepted new connection\n", .{});
        var buf: [1024]u8 = undefined;

        const len = try connection.stream.read(&buf);
        var iter = std.mem.split(u8, buf[0..len], "\r\n");

        const request = iter.next().?;
        var req_iter = std.mem.split(u8, request, " ");
        _ = req_iter.next().?;
        const target = req_iter.next().?;

        var headers = std.ArrayList(HeaderType).init(std.heap.page_allocator);
        defer headers.deinit();
        while (true) {
            const line = iter.next() orelse break;
            if (std.mem.eql(u8, line, "")) break;

            var line_iter = std.mem.split(u8, line, " ");
            const header_name = line_iter.next().?;
            const header = line_iter.next().?;

            if (std.mem.eql(u8, header_name, "User-Agent:")) {
                try headers.append(HeaderType{ .UserAgent = header });
            }
        }

        const writer = connection.stream.writer();
        const r = respond(target, headers);
        const status = if (r) |_|
            "HTTP/1.1 200 OK"
        else |err| switch (err) {
            ConnError.NotFound => "HTTP/1.1 404 Not Found",
        };
        _ = try writer.write(status[0..]);
        _ = try writer.write("\r\n");

        const response = r catch null;
        var body_len: usize = 0;
        var body_buf: [1024]u8 = undefined;
        if (response) |resp| {
            try writer.print("Content-Type: {s}\r\n", .{resp.content_type});
            body_len = std.mem.indexOfSentinel(u8, 0, &resp.buf);
            try writer.print("Content-Length: {d}\r\n", .{body_len});
            body_buf = resp.buf;
        }
        _ = try writer.write("\r\n");
        try writer.print("{s}", .{body_buf[0..body_len]});
    }
}

fn respond(target: []const u8, headers: std.ArrayList(HeaderType)) ConnError!?Response {
    var response = Response{ .buf = undefined, .content_type = undefined };

    if (std.mem.eql(u8, target, "/")) {
        return null;
    } else if (std.mem.startsWith(u8, target, "/echo")) {
        const slice = std.fmt.bufPrint(&response.buf, "{s}", .{target[6..]}) catch return ConnError.NotFound;
        response.buf[slice.len] = 0;
        response.content_type = "text/plain";
    } else if (std.mem.startsWith(u8, target, "/user-agent")) {
        var user_agent: []const u8 = undefined;
        for (headers.items) |header| {
            switch (header) {
                .UserAgent => |ua| user_agent = ua,
                else => continue,
            }
        }
        const slice = std.fmt.bufPrint(&response.buf, "{s}", .{user_agent}) catch return ConnError.NotFound;
        response.buf[slice.len] = 0;
        response.content_type = "text/plain";
    } else if (std.mem.startsWith(u8, target, "/files")) {
        const path = target[7..];
        const cwd = if (directory) |dir|
            std.fs.openDirAbsolute(dir, .{}) catch return ConnError.NotFound
        else
            std.fs.cwd();
        const slice = cwd.readFile(path, &response.buf) catch return ConnError.NotFound;
        response.buf[slice.len] = 0;
        response.content_type = "application/octet-stream";
    } else {
        return ConnError.NotFound;
    }

    return response;
}
