const std = @import("std");
const net = std.net;
const posix = std.posix;
const c = @import("render/c.zig").c;

const rate = c.SDL_NS_PER_SECOND / 20;
var lastsend: u64 = 0;
var sock: posix.socket_t = undefined;
var addr: ?*posix.sockaddr = undefined;
var addrlen: posix.socklen_t = undefined;

pub fn init(name: [:0]const u8) !void {
    addr = null;
    lastsend = 0;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.DGRAM;
    hints.flags = .{ .NUMERICSERV = true };

    var res: ?*std.c.addrinfo = null;
    const result = std.c.getaddrinfo(name, "9909", &hints, &res);
    if (@intFromEnum(result) != 0) return error.GetAddrInfo;
    addr = res.?.addr;
    addrlen = res.?.addrlen;
    sock = try posix.socket(
        @intCast(res.?.family),
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    const flags: u32 = @intCast(try posix.fcntl(sock, posix.F.GETFL, 0));
    var flags_mut: posix.O = @bitCast(flags);
    flags_mut.NONBLOCK = true;
    const flags_int: u32 = @bitCast(flags_mut);
    _ = try posix.fcntl(sock, posix.F.SETFL, @intCast(flags_int));
}

pub fn updateLights(colors: [24][3]u8) !void {
    if (addr == null) return;
    const ticks = c.SDL_GetTicksNS();
    if (ticks < lastsend + rate) {
        return;
    }
    lastsend = ticks;

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
        posix.MSG.DONTWAIT,
        addr,
        addrlen,
    );
    if (n != buf.len) {
        std.log.warn("sendto did not fullsend", .{});
    }
}
