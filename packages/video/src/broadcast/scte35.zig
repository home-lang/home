const std = @import("std");

/// SCTE-35: Digital Program Insertion Cueing Message
/// Used for ad insertion, blackout control, and program segmentation
pub const Scte35 = struct {
    /// Splice command types
    pub const CommandType = enum(u8) {
        splice_null = 0x00,
        splice_schedule = 0x04,
        splice_insert = 0x05,
        time_signal = 0x06,
        bandwidth_reservation = 0x07,
        private_command = 0xff,
    };

    /// Splice descriptor tags
    pub const DescriptorTag = enum(u8) {
        avail_descriptor = 0x00,
        dtmf_descriptor = 0x01,
        segmentation_descriptor = 0x02,
        time_descriptor = 0x03,
        audio_descriptor = 0x04,
    };

    /// Segmentation type IDs
    pub const SegmentationType = enum(u8) {
        not_indicated = 0x00,
        content_identification = 0x01,
        program_start = 0x10,
        program_end = 0x11,
        program_early_termination = 0x12,
        program_breakaway = 0x13,
        program_resumption = 0x14,
        program_runover_planned = 0x15,
        program_runover_unplanned = 0x16,
        program_overlap_start = 0x17,
        program_blackout_override = 0x18,
        chapter_start = 0x20,
        chapter_end = 0x21,
        break_start = 0x22,
        break_end = 0x23,
        provider_advertisement_start = 0x30,
        provider_advertisement_end = 0x31,
        distributor_advertisement_start = 0x32,
        distributor_advertisement_end = 0x33,
        provider_placement_opportunity_start = 0x34,
        provider_placement_opportunity_end = 0x35,
        distributor_placement_opportunity_start = 0x36,
        distributor_placement_opportunity_end = 0x37,
        unscheduled_event_start = 0x40,
        unscheduled_event_end = 0x41,
        network_start = 0x50,
        network_end = 0x51,
        _,
    };

    /// SCTE-35 splice info section
    pub const SpliceInfoSection = struct {
        table_id: u8,
        section_syntax_indicator: bool,
        private_indicator: bool,
        section_length: u12,
        protocol_version: u8,
        encrypted_packet: bool,
        encryption_algorithm: u6,
        pts_adjustment: u33,
        cw_index: u8,
        tier: u12,
        splice_command_length: u12,
        splice_command_type: CommandType,
        splice_command: SpliceCommand,
        descriptor_loop_length: u16,
        descriptors: []SpliceDescriptor,
        crc_32: u32,
    };

    /// Splice command union
    pub const SpliceCommand = union(CommandType) {
        splice_null: void,
        splice_schedule: SpliceSchedule,
        splice_insert: SpliceInsert,
        time_signal: TimeSignal,
        bandwidth_reservation: void,
        private_command: PrivateCommand,
    };

    /// Splice insert command
    pub const SpliceInsert = struct {
        splice_event_id: u32,
        splice_event_cancel_indicator: bool,
        out_of_network_indicator: bool,
        program_splice_flag: bool,
        duration_flag: bool,
        splice_immediate_flag: bool,
        splice_time: ?SpliceTime,
        component_count: u8,
        components: []ComponentSplice,
        break_duration: ?BreakDuration,
        unique_program_id: u16,
        avail_num: u8,
        avails_expected: u8,
    };

    /// Component splice for non-program mode
    pub const ComponentSplice = struct {
        component_tag: u8,
        splice_time: ?SpliceTime,
    };

    /// Splice time with PTS
    pub const SpliceTime = struct {
        time_specified_flag: bool,
        pts_time: u33, // 90kHz clock
    };

    /// Break duration for returning from splice
    pub const BreakDuration = struct {
        auto_return: bool,
        duration: u33, // 90kHz ticks
    };

    /// Time signal command
    pub const TimeSignal = struct {
        splice_time: SpliceTime,
    };

    /// Splice schedule command
    pub const SpliceSchedule = struct {
        splice_count: u8,
        events: []ScheduledEvent,
    };

    pub const ScheduledEvent = struct {
        splice_event_id: u32,
        splice_event_cancel_indicator: bool,
        out_of_network_indicator: bool,
        program_splice_flag: bool,
        duration_flag: bool,
        utc_splice_time: u32,
        component_count: u8,
        components: []ComponentSplice,
        break_duration: ?BreakDuration,
        unique_program_id: u16,
        avail_num: u8,
        avails_expected: u8,
    };

    /// Private command
    pub const PrivateCommand = struct {
        identifier: u32,
        private_bytes: []const u8,
    };

    /// Splice descriptor
    pub const SpliceDescriptor = struct {
        tag: DescriptorTag,
        length: u8,
        identifier: u32,
        data: DescriptorData,
    };

    pub const DescriptorData = union(DescriptorTag) {
        avail_descriptor: AvailDescriptor,
        dtmf_descriptor: DtmfDescriptor,
        segmentation_descriptor: SegmentationDescriptor,
        time_descriptor: TimeDescriptor,
        audio_descriptor: AudioDescriptor,
    };

    /// Avail descriptor
    pub const AvailDescriptor = struct {
        provider_avail_id: u32,
    };

    /// DTMF descriptor
    pub const DtmfDescriptor = struct {
        preroll: u8,
        dtmf_count: u8,
        dtmf_chars: []u8,
    };

    /// Segmentation descriptor (most commonly used)
    pub const SegmentationDescriptor = struct {
        segmentation_event_id: u32,
        segmentation_event_cancel_indicator: bool,
        program_segmentation_flag: bool,
        segmentation_duration_flag: bool,
        delivery_not_restricted_flag: bool,
        web_delivery_allowed_flag: bool,
        no_regional_blackout_flag: bool,
        archive_allowed_flag: bool,
        device_restrictions: u2,
        component_count: u8,
        components: []SegmentationComponent,
        segmentation_duration: u40, // microseconds
        segmentation_upid_type: u8,
        segmentation_upid_length: u8,
        segmentation_upid: []const u8,
        segmentation_type_id: SegmentationType,
        segment_num: u8,
        segments_expected: u8,
        sub_segment_num: u8,
        sub_segments_expected: u8,
    };

    pub const SegmentationComponent = struct {
        component_tag: u8,
        pts_offset: u33,
    };

    /// Time descriptor
    pub const TimeDescriptor = struct {
        tai_seconds: u48,
        tai_nanoseconds: u32,
        utc_offset: u16,
    };

    /// Audio descriptor
    pub const AudioDescriptor = struct {
        audio_count: u8,
        components: []AudioComponent,
    };

    pub const AudioComponent = struct {
        component_tag: u8,
        iso_code: [3]u8,
        bit_stream_mode: u3,
        num_channels: u4,
        full_srvc_audio: bool,
    };
};

/// SCTE-35 parser
pub const Scte35Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Scte35Parser {
        return .{ .allocator = allocator };
    }

    /// Parse SCTE-35 splice info section from binary data
    pub fn parse(self: *Scte35Parser, data: []const u8) !Scte35.SpliceInfoSection {
        var reader = std.io.fixedBufferStream(data);
        const r = reader.reader();

        var section: Scte35.SpliceInfoSection = undefined;

        section.table_id = try r.readByte();
        if (section.table_id != 0xFC) {
            return error.InvalidTableId;
        }

        const flags1 = try r.readInt(u16, .big);
        section.section_syntax_indicator = (flags1 & 0x8000) != 0;
        section.private_indicator = (flags1 & 0x4000) != 0;
        section.section_length = @truncate(flags1 & 0x0FFF);

        section.protocol_version = try r.readByte();
        if (section.protocol_version != 0) {
            return error.UnsupportedProtocolVersion;
        }

        const flags2 = try r.readByte();
        section.encrypted_packet = (flags2 & 0x80) != 0;
        section.encryption_algorithm = @truncate((flags2 & 0x7E) >> 1);

        // Read PTS adjustment (33 bits)
        const pts_bytes = try r.readInt(u64, .big);
        section.pts_adjustment = @truncate((pts_bytes >> 31) & 0x1FFFFFFFF);

        section.cw_index = try r.readByte();

        const tier_bytes = try r.readInt(u16, .big);
        section.tier = @truncate(tier_bytes & 0x0FFF);

        const cmd_len_bytes = try r.readInt(u16, .big);
        section.splice_command_length = @truncate(cmd_len_bytes & 0x0FFF);

        const cmd_type_byte = try r.readByte();
        section.splice_command_type = @enumFromInt(cmd_type_byte);

        // Parse command based on type
        section.splice_command = try self.parseCommand(r, section.splice_command_type);

        section.descriptor_loop_length = try r.readInt(u16, .big);

        // Parse descriptors
        var descriptors = std.ArrayList(Scte35.SpliceDescriptor).init(self.allocator);
        var bytes_read: u16 = 0;
        while (bytes_read < section.descriptor_loop_length) {
            const desc = try self.parseDescriptor(r);
            try descriptors.append(desc);
            bytes_read += 2 + desc.length; // tag + length + data
        }
        section.descriptors = try descriptors.toOwnedSlice();

        section.crc_32 = try r.readInt(u32, .big);

        return section;
    }

    fn parseCommand(self: *Scte35Parser, r: anytype, cmd_type: Scte35.CommandType) !Scte35.SpliceCommand {
        return switch (cmd_type) {
            .splice_null => .{ .splice_null = {} },
            .splice_insert => .{ .splice_insert = try self.parseSpliceInsert(r) },
            .time_signal => .{ .time_signal = try self.parseTimeSignal(r) },
            .bandwidth_reservation => .{ .bandwidth_reservation = {} },
            .splice_schedule => .{ .splice_schedule = try self.parseSpliceSchedule(r) },
            .private_command => .{ .private_command = try self.parsePrivateCommand(r) },
        };
    }

    fn parseSpliceInsert(self: *Scte35Parser, r: anytype) !Scte35.SpliceInsert {
        var insert: Scte35.SpliceInsert = undefined;

        insert.splice_event_id = try r.readInt(u32, .big);

        const flags1 = try r.readByte();
        insert.splice_event_cancel_indicator = (flags1 & 0x80) != 0;

        if (insert.splice_event_cancel_indicator) {
            // Cancelled event - minimal fields
            insert.out_of_network_indicator = false;
            insert.program_splice_flag = false;
            insert.duration_flag = false;
            insert.splice_immediate_flag = false;
            insert.splice_time = null;
            insert.component_count = 0;
            insert.components = &[_]Scte35.ComponentSplice{};
            insert.break_duration = null;
            insert.unique_program_id = 0;
            insert.avail_num = 0;
            insert.avails_expected = 0;
            return insert;
        }

        const flags2 = try r.readByte();
        insert.out_of_network_indicator = (flags2 & 0x80) != 0;
        insert.program_splice_flag = (flags2 & 0x40) != 0;
        insert.duration_flag = (flags2 & 0x20) != 0;
        insert.splice_immediate_flag = (flags2 & 0x10) != 0;

        if (insert.program_splice_flag and !insert.splice_immediate_flag) {
            insert.splice_time = try self.parseSpliceTime(r);
        } else {
            insert.splice_time = null;
        }

        if (!insert.program_splice_flag) {
            insert.component_count = try r.readByte();
            var components = try self.allocator.alloc(Scte35.ComponentSplice, insert.component_count);
            for (0..insert.component_count) |i| {
                components[i].component_tag = try r.readByte();
                if (!insert.splice_immediate_flag) {
                    components[i].splice_time = try self.parseSpliceTime(r);
                } else {
                    components[i].splice_time = null;
                }
            }
            insert.components = components;
        } else {
            insert.component_count = 0;
            insert.components = &[_]Scte35.ComponentSplice{};
        }

        if (insert.duration_flag) {
            insert.break_duration = try self.parseBreakDuration(r);
        } else {
            insert.break_duration = null;
        }

        insert.unique_program_id = try r.readInt(u16, .big);
        insert.avail_num = try r.readByte();
        insert.avails_expected = try r.readByte();

        return insert;
    }

    fn parseSpliceTime(self: *Scte35Parser, r: anytype) !Scte35.SpliceTime {
        _ = self;
        const flags = try r.readByte();
        const time_specified = (flags & 0x80) != 0;

        if (time_specified) {
            const pts_bytes = try r.readInt(u64, .big);
            const pts: u33 = @truncate((pts_bytes >> 31) & 0x1FFFFFFFF);
            return .{ .time_specified_flag = true, .pts_time = pts };
        } else {
            return .{ .time_specified_flag = false, .pts_time = 0 };
        }
    }

    fn parseBreakDuration(self: *Scte35Parser, r: anytype) !Scte35.BreakDuration {
        _ = self;
        const duration_bytes = try r.readInt(u64, .big);
        const auto_return = (duration_bytes & 0x8000000000) != 0;
        const duration: u33 = @truncate((duration_bytes >> 31) & 0x1FFFFFFFF);

        return .{
            .auto_return = auto_return,
            .duration = duration,
        };
    }

    fn parseTimeSignal(self: *Scte35Parser, r: anytype) !Scte35.TimeSignal {
        return .{
            .splice_time = try self.parseSpliceTime(r),
        };
    }

    fn parseSpliceSchedule(self: *Scte35Parser, r: anytype) !Scte35.SpliceSchedule {
        const splice_count = try r.readByte();
        var events = try self.allocator.alloc(Scte35.ScheduledEvent, splice_count);

        for (0..splice_count) |i| {
            events[i].splice_event_id = try r.readInt(u32, .big);
            const flags = try r.readByte();
            events[i].splice_event_cancel_indicator = (flags & 0x80) != 0;

            if (!events[i].splice_event_cancel_indicator) {
                const flags2 = try r.readByte();
                events[i].out_of_network_indicator = (flags2 & 0x80) != 0;
                events[i].program_splice_flag = (flags2 & 0x40) != 0;
                events[i].duration_flag = (flags2 & 0x20) != 0;

                events[i].utc_splice_time = try r.readInt(u32, .big);

                if (!events[i].program_splice_flag) {
                    events[i].component_count = try r.readByte();
                    var components = try self.allocator.alloc(Scte35.ComponentSplice, events[i].component_count);
                    for (0..events[i].component_count) |j| {
                        components[j].component_tag = try r.readByte();
                        components[j].splice_time = try self.parseSpliceTime(r);
                    }
                    events[i].components = components;
                } else {
                    events[i].component_count = 0;
                    events[i].components = &[_]Scte35.ComponentSplice{};
                }

                if (events[i].duration_flag) {
                    events[i].break_duration = try self.parseBreakDuration(r);
                } else {
                    events[i].break_duration = null;
                }

                events[i].unique_program_id = try r.readInt(u16, .big);
                events[i].avail_num = try r.readByte();
                events[i].avails_expected = try r.readByte();
            } else {
                // Minimal initialization for cancelled events
                events[i].out_of_network_indicator = false;
                events[i].program_splice_flag = false;
                events[i].duration_flag = false;
                events[i].utc_splice_time = 0;
                events[i].component_count = 0;
                events[i].components = &[_]Scte35.ComponentSplice{};
                events[i].break_duration = null;
                events[i].unique_program_id = 0;
                events[i].avail_num = 0;
                events[i].avails_expected = 0;
            }
        }

        return .{
            .splice_count = splice_count,
            .events = events,
        };
    }

    fn parsePrivateCommand(self: *Scte35Parser, r: anytype) !Scte35.PrivateCommand {
        const identifier = try r.readInt(u32, .big);
        // Read remaining bytes as private data
        var bytes = std.ArrayList(u8).init(self.allocator);
        while (true) {
            const byte = r.readByte() catch break;
            try bytes.append(byte);
        }

        return .{
            .identifier = identifier,
            .private_bytes = try bytes.toOwnedSlice(),
        };
    }

    fn parseDescriptor(self: *Scte35Parser, r: anytype) !Scte35.SpliceDescriptor {
        const tag_byte = try r.readByte();
        const length = try r.readByte();
        const identifier = try r.readInt(u32, .big);

        const tag: Scte35.DescriptorTag = @enumFromInt(tag_byte);

        const data = switch (tag) {
            .segmentation_descriptor => Scte35.DescriptorData{
                .segmentation_descriptor = try self.parseSegmentationDescriptor(r),
            },
            .avail_descriptor => Scte35.DescriptorData{
                .avail_descriptor = .{
                    .provider_avail_id = try r.readInt(u32, .big),
                },
            },
            .dtmf_descriptor => blk: {
                const preroll = try r.readByte();
                const dtmf_count = @as(u8, @truncate(preroll & 0x07));
                var chars = try self.allocator.alloc(u8, dtmf_count);
                _ = try r.readAll(chars);
                break :blk Scte35.DescriptorData{
                    .dtmf_descriptor = .{
                        .preroll = preroll >> 3,
                        .dtmf_count = dtmf_count,
                        .dtmf_chars = chars,
                    },
                };
            },
            .time_descriptor => Scte35.DescriptorData{
                .time_descriptor = .{
                    .tai_seconds = try r.readInt(u48, .big),
                    .tai_nanoseconds = try r.readInt(u32, .big),
                    .utc_offset = try r.readInt(u16, .big),
                },
            },
            .audio_descriptor => blk: {
                const audio_count = try r.readByte();
                var components = try self.allocator.alloc(Scte35.AudioComponent, audio_count);
                for (0..audio_count) |i| {
                    components[i].component_tag = try r.readByte();
                    _ = try r.readAll(&components[i].iso_code);
                    const flags = try r.readByte();
                    components[i].bit_stream_mode = @truncate(flags >> 5);
                    components[i].num_channels = @truncate((flags >> 1) & 0x0F);
                    components[i].full_srvc_audio = (flags & 0x01) != 0;
                }
                break :blk Scte35.DescriptorData{
                    .audio_descriptor = .{
                        .audio_count = audio_count,
                        .components = components,
                    },
                };
            },
        };

        return .{
            .tag = tag,
            .length = length,
            .identifier = identifier,
            .data = data,
        };
    }

    fn parseSegmentationDescriptor(self: *Scte35Parser, r: anytype) !Scte35.SegmentationDescriptor {
        var desc: Scte35.SegmentationDescriptor = undefined;

        desc.segmentation_event_id = try r.readInt(u32, .big);

        const flags1 = try r.readByte();
        desc.segmentation_event_cancel_indicator = (flags1 & 0x80) != 0;

        if (desc.segmentation_event_cancel_indicator) {
            // Minimal fields for cancelled
            desc.program_segmentation_flag = false;
            desc.segmentation_duration_flag = false;
            desc.delivery_not_restricted_flag = false;
            desc.web_delivery_allowed_flag = false;
            desc.no_regional_blackout_flag = false;
            desc.archive_allowed_flag = false;
            desc.device_restrictions = 0;
            desc.component_count = 0;
            desc.components = &[_]Scte35.SegmentationComponent{};
            desc.segmentation_duration = 0;
            desc.segmentation_upid_type = 0;
            desc.segmentation_upid_length = 0;
            desc.segmentation_upid = &[_]u8{};
            desc.segmentation_type_id = .not_indicated;
            desc.segment_num = 0;
            desc.segments_expected = 0;
            desc.sub_segment_num = 0;
            desc.sub_segments_expected = 0;
            return desc;
        }

        const flags2 = try r.readByte();
        desc.program_segmentation_flag = (flags2 & 0x80) != 0;
        desc.segmentation_duration_flag = (flags2 & 0x40) != 0;
        desc.delivery_not_restricted_flag = (flags2 & 0x20) != 0;

        if (!desc.delivery_not_restricted_flag) {
            const flags3 = try r.readByte();
            desc.web_delivery_allowed_flag = (flags3 & 0x80) != 0;
            desc.no_regional_blackout_flag = (flags3 & 0x40) != 0;
            desc.archive_allowed_flag = (flags3 & 0x20) != 0;
            desc.device_restrictions = @truncate((flags3 >> 3) & 0x03);
        } else {
            desc.web_delivery_allowed_flag = true;
            desc.no_regional_blackout_flag = true;
            desc.archive_allowed_flag = true;
            desc.device_restrictions = 0;
        }

        if (!desc.program_segmentation_flag) {
            desc.component_count = try r.readByte();
            var components = try self.allocator.alloc(Scte35.SegmentationComponent, desc.component_count);
            for (0..desc.component_count) |i| {
                components[i].component_tag = try r.readByte();
                const pts_bytes = try r.readInt(u64, .big);
                components[i].pts_offset = @truncate((pts_bytes >> 31) & 0x1FFFFFFFF);
            }
            desc.components = components;
        } else {
            desc.component_count = 0;
            desc.components = &[_]Scte35.SegmentationComponent{};
        }

        if (desc.segmentation_duration_flag) {
            desc.segmentation_duration = try r.readInt(u40, .big);
        } else {
            desc.segmentation_duration = 0;
        }

        desc.segmentation_upid_type = try r.readByte();
        desc.segmentation_upid_length = try r.readByte();

        var upid = try self.allocator.alloc(u8, desc.segmentation_upid_length);
        _ = try r.readAll(upid);
        desc.segmentation_upid = upid;

        const type_id = try r.readByte();
        desc.segmentation_type_id = @enumFromInt(type_id);

        desc.segment_num = try r.readByte();
        desc.segments_expected = try r.readByte();

        // Sub-segment fields (conditional based on type)
        if (desc.segmentation_type_id == .provider_placement_opportunity_start or
            desc.segmentation_type_id == .distributor_placement_opportunity_start)
        {
            desc.sub_segment_num = try r.readByte();
            desc.sub_segments_expected = try r.readByte();
        } else {
            desc.sub_segment_num = 0;
            desc.sub_segments_expected = 0;
        }

        return desc;
    }

    pub fn deinit(self: *Scte35Parser, section: *Scte35.SpliceInfoSection) void {
        switch (section.splice_command) {
            .splice_insert => |*insert| {
                if (insert.components.len > 0) {
                    self.allocator.free(insert.components);
                }
            },
            .splice_schedule => |*schedule| {
                for (schedule.events) |*event| {
                    if (event.components.len > 0) {
                        self.allocator.free(event.components);
                    }
                }
                self.allocator.free(schedule.events);
            },
            .private_command => |*cmd| {
                self.allocator.free(cmd.private_bytes);
            },
            else => {},
        }

        for (section.descriptors) |*desc| {
            switch (desc.data) {
                .segmentation_descriptor => |*seg| {
                    if (seg.components.len > 0) {
                        self.allocator.free(seg.components);
                    }
                    if (seg.segmentation_upid.len > 0) {
                        self.allocator.free(seg.segmentation_upid);
                    }
                },
                .dtmf_descriptor => |*dtmf| {
                    self.allocator.free(dtmf.dtmf_chars);
                },
                .audio_descriptor => |*audio| {
                    self.allocator.free(audio.components);
                },
                else => {},
            }
        }
        self.allocator.free(section.descriptors);
    }
};
