const std = @import("std");
const net = std.net;

const ConnError = error{
    NotFound,
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Logs from your program will appear here!\n", .{});

    const address = try net.Address.resolveIp("127.0.0.1", 4221);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const connection = try listener.accept();
    defer connection.stream.close();

    try stdout.print("accepted new connection", .{});
    var buf: [1024]u8 = undefined;

    const len = try connection.stream.read(&buf);
    var iter = std.mem.split(u8, buf[0..len], "\r\n");

    const request = iter.next().?;
    var req_iter = std.mem.split(u8, request, " ");
    _ = req_iter.next().?;
    const target = req_iter.next().?;

    const writer = connection.stream.writer();
    const r = respond(target);
    const status = if (r) |_|
        "HTTP/1.1 200 OK"
    else |err| switch (err) {
        ConnError.NotFound => "HTTP/1.1 404 Not Found",
    };
    _ = try writer.write(status[0..]);
    _ = try writer.write("\r\n");

    const resp_body = r catch null;
    var body_len: usize = 0;
    var body_buf: [1024]u8 = undefined;
    if (resp_body) |body| {
        _ = try writer.write("Content-Type: text/plain\r\n");
        body_len = std.mem.indexOfSentinel(u8, 0, &body);
        try writer.print("Content-Length: {d}\r\n", .{body_len});
        body_buf = body;
    }
    _ = try writer.write("\r\n");
    try writer.print("{s}", .{body_buf[0..body_len]});
}

fn respond(target: []const u8) ConnError!?[1024:0]u8 {
    var resp_buf: [1024:0]u8 = undefined;

    if (std.mem.eql(u8, target, "/")) {
        return null;
    } else if (std.mem.startsWith(u8, target, "/echo")) {
        const slice = std.fmt.bufPrint(&resp_buf, "{s}", .{target[6..]}) catch return ConnError.NotFound;
        resp_buf[slice.len] = 0;
    } else {
        return ConnError.NotFound;
    }

    return resp_buf;
}
