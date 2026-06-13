`timescale 1ns/1ps

module cache_controller_tb;

   localparam BLOCK_SIZE     = 256;
   localparam ADDRESS_WIDTH  = 21;
   localparam INDEX_WIDTH    = 10;
   localparam TAG_WIDTH      = 8;
   localparam OFFSET_WIDTH   = 3;
   localparam WORD_SIZE      = 32;
   localparam NBLOCKS        = 1024;
   localparam string MEM_FILE = "tb/mem_data.txt";

   // Clock period is 200 ns (100 ns high, 100 ns low).
   localparam int CLK_PERIOD_NS        = 200;
   // Read miss: IDLE -> MISS -> FETCH -> FILL -> READ_HIT -> IDLE
   localparam int MISS_LATENCY_CYCLES  = 6;
   localparam int HIT_LATENCY_CYCLES   = 2;

   logic      clock;
   logic      rst_n;

   logic [ADDRESS_WIDTH - 1:0]            caddress;
   logic [WORD_SIZE - 1:0]                cdin;
   logic [BLOCK_SIZE - 1:0]               mdin;
   logic                                  rden;
   logic                                  wren;
   logic                                  hit;
   logic [WORD_SIZE - 1:0]               cdout;
   logic [BLOCK_SIZE - 1:0]               mdout;
   logic [TAG_WIDTH + INDEX_WIDTH - 1:0]  maddress;
   logic                                  mrden;
   logic                                  mwren;

   task automatic wait_cycles(input int n);
      repeat (n) @(posedge clock);
   endtask

   task automatic cache_read(input logic [ADDRESS_WIDTH - 1:0] addr, input int wait_cycles_n);
      caddress <= addr;
      cdin     <= '0;
      rden     <= 1'b1;
      wren     <= 1'b0;
      wait_cycles(wait_cycles_n);
      rden     <= 1'b0;
      wren     <= 1'b0;
      wait_cycles(1);
   endtask

   initial begin
      $dumpfile("cache_controller_tb.vcd");
      $dumpvars;
   end

   always begin
      clock = 1'b1;
      #(CLK_PERIOD_NS / 2);
      clock = 1'b0;
      #(CLK_PERIOD_NS / 2);
   end

   cache_controller #(
      .BLOCK_SIZE(BLOCK_SIZE),
      .ADDRESS_WIDTH(ADDRESS_WIDTH),
      .INDEX_WIDTH(INDEX_WIDTH),
      .TAG_WIDTH(TAG_WIDTH),
      .OFFSET_WIDTH(OFFSET_WIDTH),
      .WORD_SIZE(WORD_SIZE),
      .NBLOCKS(NBLOCKS)
   ) DUT_CACHE (
      .clock(clock),
      .rst_n(rst_n),
      .caddress(caddress),
      .cdin(cdin),
      .mdin(mdin),
      .rden(rden),
      .wren(wren),
      .hit(hit),
      .cdout(cdout),
      .mdout(mdout),
      .maddress(maddress),
      .mrden(mrden),
      .mwren(mwren)
   );

   memory #(
      .FILE(MEM_FILE)
   ) DUT_MEM (
      .clock(clock),
      .din(mdout),
      .address(maddress),
      .rden(mrden),
      .wren(mwren),
      .dout(mdin)
   );

   initial begin
      caddress = '0;
      cdin     = '0;
      rden     = 1'b0;
      wren     = 1'b0;
      rst_n    = 1'b0;

      wait_cycles(2);
      rst_n = 1'b1;
      wait_cycles(1);

      // Cold read: expect miss, then fill completes within MISS_LATENCY_CYCLES
      cache_read(21'h00004, MISS_LATENCY_CYCLES);

      // Same set/tag/line (wider constants truncate to the same 21-bit address)
      cache_read(21'h00004, HIT_LATENCY_CYCLES);

      // Same cache line, different word offset: expect hit
      cache_read(21'h00005, HIT_LATENCY_CYCLES);

      cache_read(21'h00006, HIT_LATENCY_CYCLES);

      cache_read(21'h00007, HIT_LATENCY_CYCLES);

      wait_cycles(2);
      $finish;
   end

   initial begin
      $monitor(
         "time=%5d | addr=%h | hit=%b | cdout=%08x | cache[0]=%h",
         $time,
         caddress,
         hit,
         cdout,
         DUT_CACHE.cache_mem[0]
      );
   end

endmodule
