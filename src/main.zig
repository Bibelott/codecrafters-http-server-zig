const std = @import("std");
const net = std.net;
const gzip = std.compress.gzip;

const HeaderType = union(enum) {
    Host: []const u8,
    UserAgent: []const u8,
    Accept: []const u8,
    AcceptEncoding: []const u8,
};

const RequestType = enum {
    GET,
    POST,
};

const buf_len = 1024;

const Response = struct {
    code: ResponseCode,
    body: ?ResponseBody,
};
const ResponseCode = enum {
    OK,
    FileCreated,
    NotFound,
};
const ResponseBody = struct {
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
        const req_type: RequestType = if (std.mem.eql(u8, req_iter.next().?, "POST")) RequestType.POST else RequestType.GET;
        const target = req_iter.next().?;

        var headers = std.ArrayList(HeaderType).init(std.heap.page_allocator);
        defer headers.deinit();
        var encoding = false;
        while (true) {
            const line = iter.next() orelse break;
            if (std.mem.eql(u8, line, "")) break;

            var line_iter = std.mem.split(u8, line, " ");
            const header_name = line_iter.next().?;
            const header = line_iter.rest();

            if (std.mem.eql(u8, header_name, "User-Agent:")) {
                try headers.append(HeaderType{ .UserAgent = header });
            } else if (std.mem.eql(u8, header_name, "Accept-Encoding:")) {
                var i = std.mem.splitSequence(u8, header, ", ");
                while (i.next()) |enc| {
                    if (std.mem.eql(u8, enc, "gzip")) encoding = true;
                }
            }
        }

        const req_body = iter.next().?;

        const writer = connection.stream.writer();
        const response = respond(target, req_type, headers, req_body);
        const status: []const u8 = switch (response.code) {
            .OK => "HTTP/1.1 200 OK",
            .FileCreated => "HTTP/1.1 201 Created",
            .NotFound => "HTTP/1.1 404 Not Found",
        };
        _ = try writer.write(status[0..]);
        _ = try writer.write("\r\n");

        var body_len: usize = 0;
        var body_buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer body_buf.deinit();
        var body_writer = body_buf.writer();

        if (response.body) |body| {
            try writer.print("Content-Type: {s}\r\n", .{body.content_type});
            const uncompressed_len = std.mem.indexOfSentinel(u8, 0, &body.buf);
            if (encoding) {
                _ = try writer.write("Content-Encoding: gzip\r\n");
                var compressor = try gzip.compressor(body_writer, .{});
                _ = try compressor.write(body.buf[0..uncompressed_len]);
                try compressor.finish();
            } else {
                _ = try body_writer.write(body.buf[0..uncompressed_len]);
            }
            body_len = body_buf.items.len;
            try writer.print("Content-Length: {d}\r\n", .{body_len});
        }

        _ = try writer.write("\r\n");
        try writer.writeAll(body_buf.items);
    }
}

fn respond(target: []const u8, req_type: RequestType, headers: std.ArrayList(HeaderType), req_body: []const u8) Response {
    var response = Response{ .code = .NotFound, .body = null };
    var body = ResponseBody{ .buf = undefined, .content_type = undefined };

    if (std.mem.eql(u8, target, "/")) {
        response.code = .OK;
        return response;
    } else if (std.mem.startsWith(u8, target, "/echo")) {
        const slice = std.fmt.bufPrint(&body.buf, "{s}", .{target[6..]}) catch return response;
        body.buf[slice.len] = 0;
        body.content_type = "text/plain";
        response.code = .OK;
        response.body = body;
    } else if (std.mem.startsWith(u8, target, "/user-agent")) {
        var user_agent: []const u8 = undefined;
        for (headers.items) |header| {
            switch (header) {
                .UserAgent => |ua| user_agent = ua,
                else => continue,
            }
        }
        const slice = std.fmt.bufPrint(&body.buf, "{s}", .{user_agent}) catch return response;
        body.buf[slice.len] = 0;
        body.content_type = "text/plain";
        response.code = .OK;
        response.body = body;
    } else if (std.mem.startsWith(u8, target, "/files")) {
        const path = target[7..];
        const cwd = if (directory) |dir|
            std.fs.openDirAbsolute(dir, .{}) catch return response
        else
            std.fs.cwd();
        if (req_type == .GET) {
            const slice = cwd.readFile(path, &body.buf) catch return response;
            body.buf[slice.len] = 0;
            body.content_type = "application/octet-stream";
            response.code = .OK;
            response.body = body;
        } else if (req_type == .POST) {
            const file = cwd.createFile(path, .{}) catch return response;
            _ = file.write(req_body) catch return response;
            response.code = .FileCreated;
        }
    }
    return response;
}
