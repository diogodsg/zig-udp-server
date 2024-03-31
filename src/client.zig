const std = @import("std");
const os = std.os;
const net = std.net;

const BUFFER_SIZE = 1024 * 4;
const GetFileResponse = struct { filename: []const u8, part: u32, totalParts: u32, checkSum: u32, data: []const u8 };

fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    var line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    // trim annoying windows-only carriage return character
    if (@import("builtin").os.tag == .windows) {
        return std.mem.trimRight(u8, line, "\r");
    } else {
        return line;
    }
}

const Socket = struct {
    address: net.Address,
    socket: os.socket_t,

    pub fn init(ip: []const u8, port: u16) !Socket {
        const parsed_address = try net.Address.parseIp4(ip, port);
        const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM, 0);
        errdefer os.closeSocket(sock);
        return Socket{ .address = parsed_address, .socket = sock };
    }

    pub fn bind(self: *Socket) !void {
        try os.bind(self.socket, &self.address.any, self.address.getOsSockLen());
    }

    pub fn listen(self: *Socket) !void {
        var buffer: [BUFFER_SIZE]u8 = undefined;
        while (true) {
            const bytesRead = try os.recvfrom(self.socket, buffer[0..], 0, null, null);

            if (bytesRead == 0) break;

            const message = buffer[0..bytesRead];

            std.debug.print("Received {d} bytes\n", .{bytesRead});
            var parts = std.mem.split(u8, message, "\n--data=");
            const headers = parts.next().?;
            const data = parts.next().?;

            var it = std.mem.split(u8, headers, "\n");
            var fileResponse = GetFileResponse{ .filename = "", .part = 0, .totalParts = 0, .data = "", .checkSum = 512647 };
            while (it.next()) |x| {
                std.debug.print("Reading {s}\n", .{x});

                var index = std.mem.indexOf(u8, x, "=").?;
                if (std.mem.eql(u8, x[0..index], "--output-file")) {
                    fileResponse.filename = x[index + 1 ..];
                } else if (std.mem.eql(u8, x[0..index], "--checksum")) {
                    fileResponse.checkSum = try std.fmt.parseInt(u32, x[index + 1 ..], 10);
                } else if (std.mem.eql(u8, x[0..index], "--parts")) {
                    var partsIndex = std.mem.indexOf(u8, x[index + 1 ..], "/").?;
                    const current = partsIndex.next().?;
                    const total = partsIndex.next().?;

                    fileResponse.part = try std.fmt.parseInt(u32, current, 10);
                    fileResponse.totalParts = try std.fmt.parseInt(u32, total, 10);
                }
            }
            fileResponse.data = data;
            const filename = fileResponse.filename;
            std.fs.cwd().access(filename, .{}) catch |e|
                switch (e) {
                error.FileNotFound => {
                    std.log.err("File {s} doesn't exists, creating...", .{filename});
                    const createdFile = try std.fs.cwd().createFile(filename, .{});
                    defer createdFile.close();
                },
                else => return e,
            };
            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_write });
            defer file.close();
            var stat = try file.stat();
            try file.seekTo(stat.size);

            try file.writeAll(fileResponse.data);
        }
    }
};

pub fn sendMessage() !void {
    const ip = "127.0.0.1";
    const port: u16 = 3000;

    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();

    try stdout.writeAll(
        \\ Enter your name:
    );

    var input_buffer: [100]u8 = undefined;
    const input = (try nextLine(stdin.reader(), &input_buffer)).?;
    try stdout.writer().print(
        "Your name is: \"{s}\"\n",
        .{input},
    );

    const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM, 0);
    defer os.closeSocket(sock);

    const address = try std.net.Address.parseIp4(ip, port);
    const message = "GET /file\n--file-name=file.txt";
    _ = try os.sendto(sock, message, 0, &address.any, address.getOsSockLen());
}

pub fn main() !void {
    var socket = try Socket.init("127.0.0.1", 3001);
    try socket.bind();
    _ = try sendMessage();
    try socket.listen();
}
