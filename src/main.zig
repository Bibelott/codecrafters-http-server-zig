const std = @import("std");
const net = std.net;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Logs from your program will appear here!\n", .{});

    const address = try net.Address.resolveIp("127.0.0.1", 4221);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const connection = try listener.accept();

    try stdout.print("accepted new connection", .{});
    var buf: [1024]u8 = undefined;

    const len = try connection.stream.read(&buf);
    var iter = std.mem.split(u8, buf[0..len], "\r\n");
    const request = iter.next().?;
    var req_iter = std.mem.split(u8, request, " ");
    _ = req_iter.next().?;
    const target = req_iter.next().?;
    if (std.mem.eql(u8, target, "/")) {
        _ = try connection.stream.write("HTTP/1.1 200 OK\r\n\r\n");
    } else {
        _ = try connection.stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
    }

    connection.stream.close();
}
