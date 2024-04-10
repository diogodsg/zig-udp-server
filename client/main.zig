const std = @import("std");
const os = std.os;
const net = std.net;

const BUFFER_SIZE = 1024 * 4;
const GetFileResponse = struct { filename: []const u8, part: u32, totalParts: u32, partChecksum: u32, checkSum: u32, data: []const u8 };

pub fn generateCheckSum(filename: []const u8) !u32 {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var crc32 = std.hash.Crc32.init();

    var buffer: [BUFFER_SIZE]u8 = undefined;
    while (true) {
        const bytesRead = try file.read(buffer[0..]);
        if (bytesRead == 0) break;
        crc32.update(buffer[0..bytesRead]);
    }

    const checksum = crc32.final();

    std.debug.print("CRC32 checksum for file '{s}' is: {x}\n", .{ filename, checksum });

    return checksum;
}

pub fn generatePartCheckSum(data: []const u8) !u32 {
    var crc32 = std.hash.Crc32.init();

    crc32.update(data);

    const checksum = crc32.final();

    std.debug.print("CRC32 checksum is: {d}\n", .{checksum});

    return checksum;
}

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

    pub fn receiveFile(self: *Socket, requestFilename: []const u8, shouldCorrupt: []const u8) !void {
        var buffer: [BUFFER_SIZE]u8 = undefined;
        var memoryAllocated = false;
        const allocator = std.heap.page_allocator;
        var prng = std.rand.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.os.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });

        const rand = prng.random();

        var ptr = try allocator.alloc(u8, 100);
        var receivedparts = try allocator.alloc(u8, 1024);
        for (0..receivedparts.len) |i| {
            receivedparts[i] = 0;
        }
        defer allocator.free(ptr);
        var allocationCounter: usize = 0;
        var allocationCounterV2: usize = 0;
        var counter: usize = 0;

        const ip = "127.0.0.1";
        const port: u16 = 3000;
        const address = try std.net.Address.parseIp4(ip, port);

        while (true) {
            const randomValue = rand.intRangeAtMost(u8, 0, 1);
            const corruptString = if (randomValue == 0 and std.mem.eql(u8, shouldCorrupt, "y")) "\n--corrupt=true" else "\n--corrupt=false";

            var requestMessage = try std.fmt.allocPrint(allocator, "GET /file\n--file-name={s}\n--part={}{s}", .{ requestFilename, counter, corruptString });
            std.debug.print("\n\nrequesting page {}\n{s}\n\n", .{ counter, requestMessage });
            _ = try os.sendto(self.socket, requestMessage, 0, &address.any, address.getOsSockLen());

            const bytesRead = try os.recvfrom(self.socket, buffer[0..], 0, null, null);

            if (bytesRead == 0) {
                break;
            }

            const message = buffer[0..bytesRead];
            if (std.mem.eql(u8, message, "File Not Found")) {
                return;
            }
            std.debug.print("Received {d} bytes\n", .{bytesRead});

            var parts = std.mem.split(u8, message, "\n--data=");

            const headers = parts.next().?;
            const data = parts.next().?;

            var it = std.mem.split(u8, headers, "\n");
            var fileResponse = GetFileResponse{ .filename = "", .part = 0, .totalParts = 0, .partChecksum = 0, .data = "", .checkSum = 0 };
            while (it.next()) |x| {
                std.debug.print("Reading {s}\n", .{x});

                var index = std.mem.indexOf(u8, x, "=").?;
                if (std.mem.eql(u8, x[0..index], "--output-file")) {
                    fileResponse.filename = x[index + 1 ..];
                } else if (std.mem.eql(u8, x[0..index], "--checksum")) {
                    var partsIndex = std.mem.split(u8, x[index + 1 ..], "/");
                    const part = partsIndex.next().?;
                    const total = partsIndex.next().?;
                    fileResponse.partChecksum = try std.fmt.parseInt(u32, part, 10);
                    fileResponse.checkSum = try std.fmt.parseInt(u32, total, 10);
                } else if (std.mem.eql(u8, x[0..index], "--parts")) {
                    var partsIndex = std.mem.split(u8, x[index + 1 ..], "/");
                    const current = partsIndex.next().?;
                    const total = partsIndex.next().?;

                    fileResponse.part = try std.fmt.parseInt(u32, current, 10);
                    fileResponse.totalParts = try std.fmt.parseInt(u32, total, 10);
                }
            }
            fileResponse.data = data;

            const partChecksum = try generatePartCheckSum(data);
            if (partChecksum != fileResponse.partChecksum and fileResponse.part != fileResponse.totalParts) {
                std.debug.print("checksum failed {} ...\n", .{counter});
                continue;
            }

            if (!memoryAllocated) {
                const arraySize: usize = (BUFFER_SIZE * (fileResponse.totalParts + 2)) / @sizeOf(u8);
                std.debug.print("size of the received file {}\n", .{arraySize});
                ptr = try allocator.alloc(u8, arraySize);
                std.debug.print("allocated {}\n", .{ptr.len});

                memoryAllocated = true;
            }

            for (0..(fileResponse.data.len)) |j| {
                ptr[((BUFFER_SIZE - headers.len - 8) * fileResponse.part) + j] = fileResponse.data[j];
            }

            allocationCounter += fileResponse.data.len;
            receivedparts[fileResponse.part] = 1;
            // std.debug.print("allocating {}, {} {}  \n", .{ fileResponse.data.len == ((BUFFER_SIZE - headers.len - 8)), fileResponse.data.len, headers.len });
            allocationCounterV2 += fileResponse.data.len;
            const filename = fileResponse.filename;
            std.fs.cwd().access(filename, .{}) catch |e|
                switch (e) {
                error.FileNotFound => {
                    std.debug.print("File {s} doesn't exists, creating...", .{filename});
                    const createdFile = try std.fs.cwd().createFile(filename, .{});
                    defer createdFile.close();
                },
                else => return e,
            };

            if (fileResponse.part == fileResponse.totalParts) {
                // try std.fs.cwd().deleteFile(fileResponse.filename);
                const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_write });
                defer file.close();
                var stat = try file.stat();
                try file.seekTo(stat.size);
                try file.writeAll(ptr[0..(allocationCounter)]);

                const checksum = try generateCheckSum(fileResponse.filename);
                if (checksum == fileResponse.checkSum) {
                    std.debug.print("Checksum succed!\n", .{});
                    return;
                } else {
                    std.debug.print("Checksum failed!\n", .{});
                    allocationCounter -= fileResponse.data.len;
                    try std.fs.cwd().deleteFile(fileResponse.filename);
                    continue;
                }
            }
            counter += 1;
        }
    }
};

pub fn sendMessage() !void {
    // const ip = "127.0.0.1";
    // const port: u16 = 3000;

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

    // const address = try std.net.Address.parseIp4(ip, port);
    // const message = "GET /file\n--file-name=file.txt\n--part=0";
    // _ = try os.sendto(sock, message, 0, &address.any, address.getOsSockLen());
}

pub fn main() !void {
    var socket = try Socket.init("127.0.0.1", 3001);
    try socket.bind();

    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();

    try stdout.writeAll(
        \\ Enter the file name: 
    );

    var input_buffer_filename: [100]u8 = undefined;
    const filename = (try nextLine(stdin.reader(), &input_buffer_filename)).?;
    // std.debug.print("\n\nFile Name: x{s}x\n\n", .{filename});

    try stdout.writeAll(
        \\ Should Corrupt (y/n): 
    );
    var input_buffer_should_corrupt: [100]u8 = undefined;

    const shouldCorrupt = (try nextLine(stdin.reader(), &input_buffer_should_corrupt)).?;

    // _ = try sendMessage();

    try socket.receiveFile(filename, shouldCorrupt);
}
