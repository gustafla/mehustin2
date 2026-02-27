const std = @import("std");
const c = std.c;
const net = std.net;
const posix = std.posix;

var sock: posix.socket_t = undefined;
var addr: posix.sockaddr = undefined;
var addrlen: posix.socklen_t = undefined;

pub fn init(name: [:0]const u8) !void {
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.INET;
    hints.socktype = c.SOCK.DGRAM;
    hints.flags = .{ .NUMERICSERV = true };

    var res: ?*c.addrinfo = null;
    const result = c.getaddrinfo(name, "9909", &hints, &res);
    if (@intFromEnum(result) != 0) return error.GetAddrInfo;
    addr = res.?.addr.?.*;
    addrlen = res.?.addrlen;
    sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
}

pub fn updateLights(r: u8, g: u8, b: u8) !void {
    _ = r;
    _ = g;
    _ = b;
    const buf = .{ 1, 0, 'M', 'e', 'h', 'u', 0 };

    const n = try posix.sendto(
        sock,
        &buf,
        0,
        &addr,
        addrlen,
    );
    if (n != buf.len) {
        std.log.warn("sendto did not fullsend", .{});
    }
}
