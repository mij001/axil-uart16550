`timescale 1ns / 1ps

// drives frames onto sin and decodes them off sout. no register map here

module serial_bfm (
    input  wire aclk,
    output reg  line_out,
    input  wire line_in
);

    // ---------------------------------------------------------------- driver
    integer drv_frames;

    initial begin
        line_out   = 1'b1;
        drv_frames = 0;
    end

    function par_bit;
        input [7:0]   d;
        input integer wbits;
        input integer mode;
        reg   [7:0]   m;
        begin
            m = d & ((8'd1 << wbits) - 8'd1);
            case (mode)
                1:       par_bit = ~^m;
                2:       par_bit =  ^m;
                3:       par_bit = 1'b1;
                default: par_bit = 1'b0;
            endcase
        end
    endfunction

    // wait until 3 ns after the next rising edge
    task align;
        begin
            @(posedge aclk);
            #3;
        end
    endtask

    //  send one frame. flags: bit 0 flip the parity bit (parity error) bit 1 make the
    task send;
        input [7:0]   d;
        input integer wbits;
        input integer pmode;
        input integer stop_halves;
        input integer bit_ns;
        input integer flags;
        integer i;
        reg     p;
        begin
            if (!flags[2]) align;
            line_out = 1'b0;                              // start bit
            #(bit_ns);
            for (i = 0; i < wbits; i = i + 1) begin
                line_out = d[i];
                #(bit_ns);
            end
            if (pmode != 0) begin
                p = par_bit(d, wbits, pmode) ^ flags[0];
                line_out = p;
                #(bit_ns);
            end
            if (!flags[3]) begin
                line_out = flags[1] ? 1'b0 : 1'b1;        // first stop bit
                #(bit_ns);
                line_out = 1'b1;
                #((stop_halves - 2) * bit_ns / 2);
            end
            drv_frames = drv_frames + 1;
        end
    endtask

    // hold the line low for the given number of bit times, then release it
    task send_break;
        input integer bits;
        input integer bit_ns;
        begin
            align;
            line_out = 1'b0;
            #(bits * bit_ns);
            line_out = 1'b1;
            #(bit_ns);
        end
    endtask

    // a short low pulse that must not be mistaken for a start bit
    task glitch;
        input integer width_ns;
        begin
            align;
            line_out = 1'b0;
            #(width_ns);
            line_out = 1'b1;
        end
    endtask

    task idle;
        input integer ns;
        begin
            line_out = 1'b1;
            #(ns);
        end
    endtask

    // ---------------------------------------------------------------- monitor
    integer    mon_en;
    integer    mon_width_check;   // off while software drives a break (not bit aligned)
    integer    mon_bit_ns;
    integer    mon_wbits;
    integer    mon_pmode;
    integer    mon_stop_halves;

    reg [7:0]  mq_data   [0:63];
    reg        mq_par    [0:63];
    reg        mq_stopok [0:63];
    real       mq_start  [0:63];   // time of each frame's start edge
    realtime   last_start;         // start time of the frame last taken by expect_frame
    integer    mq_head, mq_tail;
    integer    mon_frames;
    integer    mon_width_errors;

    initial begin
        mon_en = 0; mon_width_check = 1; mon_bit_ns = 160; mon_wbits = 8; mon_pmode = 0; mon_stop_halves = 2;
        mq_head = 0; mq_tail = 0; mon_frames = 0; mon_width_errors = 0; last_start = 0;
    end

    //  width of every low stretch on line_in, measured between changes. in a correct
    realtime last_change;
    reg      last_level;
    real     ratio;
    integer  nearest;
    initial begin last_change = 0; last_level = 1'b1; end

    always @(line_in) begin
        if (mon_en != 0 && mon_width_check != 0 && last_level == 1'b0) begin
            ratio   = ($realtime - last_change) / mon_bit_ns;
            nearest = $rtoi(ratio + 0.5);
            if (ratio - nearest > 0.001 || nearest - ratio > 0.001) begin
                mon_width_errors = mon_width_errors + 1;
                $display("[%0t] SERIAL MONITOR: low stretch of %0.1f ns is not a whole number of %0d ns bits",
                         $time, $realtime - last_change, mon_bit_ns);
            end
        end
        last_change = $realtime;
        last_level  = line_in;
    end

    task decode_one;         // body of the monitor loop, one frame
        integer  i;
        reg [7:0] d;
        reg       p, ok;
        realtime  t0;
        begin
            @(negedge line_in);
            t0 = $realtime;
            if (mon_en != 0) begin
                #(mon_bit_ns / 2);                        // centre of the start bit
                if (line_in == 1'b0) begin
                    d = 8'h00;
                    for (i = 0; i < mon_wbits; i = i + 1) begin
                        #(mon_bit_ns);
                        d[i] = line_in;
                    end
                    p = 1'b0;
                    if (mon_pmode != 0) begin
                        #(mon_bit_ns);
                        p = line_in;
                    end
                    #(mon_bit_ns);
                    ok = line_in;                         // centre of the first stop bit
                    //  and again a quarter bit before the stop bits must end, so a
                    #((2 * mon_stop_halves - 3) * mon_bit_ns / 4);
                    ok = ok & line_in;
                    mq_start[mq_tail]  = t0;
                    mq_data[mq_tail]   = d;
                    mq_par[mq_tail]    = p;
                    mq_stopok[mq_tail] = ok;
                    mq_tail            = (mq_tail + 1) % 64;
                    mon_frames         = mon_frames + 1;
                end
            end
        end
    endtask

    always begin
        decode_one;
    end

    function mon_empty;
        input dummy;
        begin
            mon_empty = (mq_head == mq_tail);
        end
    endfunction

    // take the oldest decoded frame, and check it against what was expected
    task expect_frame;
        input  [7:0] d;
        output       ok;
        reg    [7:0] m;
        begin
            ok = 1'b1;
            m  = d & ((8'd1 << mon_wbits) - 8'd1);
            if (mq_head == mq_tail) begin
                $display("[%0t] SERIAL MONITOR: expected 0x%02h but no frame was seen", $time, m);
                ok = 1'b0;
            end else begin
                if (mq_data[mq_head] !== m) begin
                    $display("[%0t] SERIAL MONITOR: data 0x%02h, expected 0x%02h", $time, mq_data[mq_head], m);
                    ok = 1'b0;
                end
                if (mon_pmode != 0 && mq_par[mq_head] !== par_bit(m, mon_wbits, mon_pmode)) begin
                    $display("[%0t] SERIAL MONITOR: parity bit %b wrong for 0x%02h", $time, mq_par[mq_head], m);
                    ok = 1'b0;
                end
                if (mq_stopok[mq_head] !== 1'b1) begin
                    $display("[%0t] SERIAL MONITOR: stop bits not high for 0x%02h", $time, m);
                    ok = 1'b0;
                end
                last_start = mq_start[mq_head];
                mq_head = (mq_head + 1) % 64;
            end
        end
    endtask

    task mon_flush;
        begin
            mq_head = mq_tail;
        end
    endtask

endmodule
