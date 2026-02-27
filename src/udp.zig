const std = @import("std");
const c = std.c;
const net = std.net;
const posix = std.posix;

var sock: posix.socket_t = undefined;
var addr: ?*posix.sockaddr = undefined;
var addrlen: posix.socklen_t = undefined;

pub fn init(name: [:0]const u8) !void {
    addr = null;
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.UNSPEC;
    hints.socktype = c.SOCK.DGRAM;
    hints.flags = .{ .NUMERICSERV = true };

    var res: ?*c.addrinfo = null;
    const result = c.getaddrinfo(name, "9909", &hints, &res);
    if (@intFromEnum(result) != 0) return error.GetAddrInfo;
    addr = res.?.addr;
    addrlen = res.?.addrlen;
    sock = try posix.socket(
        @intCast(res.?.family),
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
}

pub fn updateLights(colors: [24][3]u8) !void {
    if (addr == null) return;

    const nlights = 24;
    const nick_tag: [7]u8 = .{ 1, 0, 'M', 'e', 'h', 'u', 0 };
    const cmd_init: [6]u8 = .{1} ++ .{0} ** 5;

    var buf = nick_tag ++ cmd_init ** nlights;
    const cmds = buf[nick_tag.len..];
    for (0..nlights) |i| {
        const cmd = cmds[cmd_init.len * i ..][0..6];
        const r, const g, const b = colors[i];
        cmd[1] = @intCast(i);
        cmd[3] = r;
        cmd[4] = g;
        cmd[5] = b;
    }

    const n = try posix.sendto(
        sock,
        &buf,
        0,
        addr,
        addrlen,
    );
    if (n != buf.len) {
        std.log.warn("sendto did not fullsend", .{});
    }
}
