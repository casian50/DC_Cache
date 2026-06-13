`timescale 1ns/1ps

module cache_controller_tb;

   //--------------------------------------------------------------------------
   // Geometry for 32 KiB, 4-way set associative cache
   //--------------------------------------------------------------------------
   localparam BLOCK_SIZE     = 256;
   localparam ADDRESS_WIDTH  = 21;
   localparam INDEX_WIDTH    = 8;     // 256 sets
   localparam TAG_WIDTH      = 10;
   localparam OFFSET_WIDTH   = 3;
   localparam WORD_SIZE      = 32;
   localparam NWAYS          = 4;
   localparam NSETS          = 256;
   localparam string MEM_FILE = "tb/mem_data.txt";

   localparam int CLK_PERIOD_NS        = 200;
   localparam int MISS_LATENCY_CYCLES  = 6;  // IDLE->MISS->(REPLACE)->FETCH->FILL->HIT
   localparam int HIT_LATENCY_CYCLES   = 2;  // IDLE->HIT

   logic clock;
   logic rst_n;

   logic [ADDRESS_WIDTH - 1:0]            caddress;
   logic [WORD_SIZE - 1:0]                cdin;
   logic [BLOCK_SIZE - 1:0]               mdin;
   logic                                  rden;
   logic                                  wren;
   logic                                  hit;
   logic [WORD_SIZE - 1:0]                cdout;
   logic [BLOCK_SIZE - 1:0]               mdout;
   logic [TAG_WIDTH + INDEX_WIDTH - 1:0]  maddress;
   logic                                  mrden;
   logic                                  mwren;

   logic sampled_hit;
   logic [WORD_SIZE - 1:0] last_cdout;
   int   pass_count = 0;
   int   fail_count = 0;

   // Capture the word delivered during a read-hit (cdout is only valid then).
   always @(posedge clock)
      if (DUT_CACHE.current_state == DUT_CACHE.STATE_READ_HIT)
         last_cdout <= cdout;

   //--------------------------------------------------------------------------
   // Helpers
   //--------------------------------------------------------------------------
   task automatic wait_cycles(input int n);
      repeat (n) @(posedge clock);
   endtask

   // Build a word address from (tag, index, offset).
   function automatic logic [ADDRESS_WIDTH - 1:0] make_addr(
      input int tag, input int index, input int offset);
      return (tag << (INDEX_WIDTH + OFFSET_WIDTH)) |
             (index << OFFSET_WIDTH) | offset;
   endfunction

   // Issue an access, sample the hit/miss decision, check it, then wait
   // long enough for the transaction to complete.
   task automatic cache_access(input logic [ADDRESS_WIDTH - 1:0] addr,
                               input bit                         is_write,
                               input logic [WORD_SIZE - 1:0]     wdata,
                               input bit                         exp_hit,
                               input int                         total_cycles,
                               input string                      name);
      caddress = addr;
      cdin     = wdata;
      rden     = ~is_write;
      wren     =  is_write;
      #1;                       // combinational settle while still in IDLE
      sampled_hit = hit;
      if (sampled_hit === exp_hit) begin
         pass_count++;
         $display("  [PASS] %-26s addr=%05h hit=%0d (exp %0d)",
                  name, addr, sampled_hit, exp_hit);
      end else begin
         fail_count++;
         $display("  [FAIL] %-26s addr=%05h hit=%0d (exp %0d)",
                  name, addr, sampled_hit, exp_hit);
      end
      wait_cycles(total_cycles);
      rden = 1'b0;
      wren = 1'b0;
      wait_cycles(1);
   endtask

   task automatic do_read(input logic [ADDRESS_WIDTH-1:0] addr,
                          input bit exp_hit, input string name);
      cache_access(addr, 1'b0, '0, exp_hit,
                   exp_hit ? HIT_LATENCY_CYCLES : MISS_LATENCY_CYCLES, name);
   endtask

   task automatic do_write(input logic [ADDRESS_WIDTH-1:0] addr,
                           input logic [WORD_SIZE-1:0] data,
                           input bit exp_hit, input string name);
      cache_access(addr, 1'b1, data, exp_hit,
                   exp_hit ? HIT_LATENCY_CYCLES : MISS_LATENCY_CYCLES, name);
   endtask

   //--------------------------------------------------------------------------
   // Waveforms
   //--------------------------------------------------------------------------
   initial begin
      $dumpfile("cache_controller_tb.vcd");
      $dumpvars;
   end

   // Visibility into memory traffic
   always @(posedge clock) begin
      if (mwren)
         $display("        >> WRITE-BACK  maddr=%05h  word0=%08h", maddress, mdout[31:0]);
      if (mrden)
         $display("        >> FETCH       maddr=%05h", maddress);
   end

   always begin
      clock = 1'b1;
      #(CLK_PERIOD_NS / 2);
      clock = 1'b0;
      #(CLK_PERIOD_NS / 2);
   end

   //--------------------------------------------------------------------------
   // DUT
   //--------------------------------------------------------------------------
   cache_controller #(
      .BLOCK_SIZE(BLOCK_SIZE),
      .ADDRESS_WIDTH(ADDRESS_WIDTH),
      .INDEX_WIDTH(INDEX_WIDTH),
      .TAG_WIDTH(TAG_WIDTH),
      .OFFSET_WIDTH(OFFSET_WIDTH),
      .WORD_SIZE(WORD_SIZE),
      .NWAYS(NWAYS),
      .NSETS(NSETS)
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

   //--------------------------------------------------------------------------
   // Stimulus
   //--------------------------------------------------------------------------
   initial begin
      caddress = '0;
      cdin     = '0;
      rden     = 1'b0;
      wren     = 1'b0;
      rst_n    = 1'b0;

      wait_cycles(2);
      rst_n = 1'b1;
      wait_cycles(1);

      $display("\n================ TEST 1: basic read miss then hits (same line) ================");
      // set 0, tag 0, walking word offsets 4..7 (one cold miss, rest hit)
      do_read(make_addr(0,0,4), 1'b0, "cold read set0/word4");
      do_read(make_addr(0,0,4), 1'b1, "reread  set0/word4");
      do_read(make_addr(0,0,5), 1'b1, "read    set0/word5");
      do_read(make_addr(0,0,6), 1'b1, "read    set0/word6");
      do_read(make_addr(0,0,7), 1'b1, "read    set0/word7");

      $display("\n================ TEST 2: 4-way associativity, set 1 ===========================");
      // Four distinct tags into the SAME set -> 4 cold misses, all coexist.
      do_read(make_addr(0,1,0), 1'b0, "fill way (tag0) set1");
      do_read(make_addr(1,1,0), 1'b0, "fill way (tag1) set1");
      do_read(make_addr(2,1,0), 1'b0, "fill way (tag2) set1");
      do_read(make_addr(3,1,0), 1'b0, "fill way (tag3) set1");
      // All four still present -> hits (this is impossible in a direct-mapped cache)
      do_read(make_addr(0,1,0), 1'b1, "still present tag0 set1");
      do_read(make_addr(1,1,0), 1'b1, "still present tag1 set1");
      do_read(make_addr(2,1,0), 1'b1, "still present tag2 set1");
      do_read(make_addr(3,1,0), 1'b1, "still present tag3 set1");

      $display("\n================ TEST 3: LRU replacement, set 2 ===============================");
      do_read(make_addr(0,2,0), 1'b0, "fill tag0 set2");   // LRU order: 0
      do_read(make_addr(1,2,0), 1'b0, "fill tag1 set2");   //            0,1
      do_read(make_addr(2,2,0), 1'b0, "fill tag2 set2");   //            0,1,2
      do_read(make_addr(3,2,0), 1'b0, "fill tag3 set2");   // full -> LRU=tag0
      do_read(make_addr(0,2,0), 1'b1, "touch tag0 (now MRU)"); // LRU=tag1 now
      do_read(make_addr(4,2,0), 1'b0, "insert tag4 -> evict LRU(tag1)");
      // Verify survivors and the eviction:
      do_read(make_addr(0,2,0), 1'b1, "tag0 survived");
      do_read(make_addr(2,2,0), 1'b1, "tag2 survived");
      do_read(make_addr(3,2,0), 1'b1, "tag3 survived");
      do_read(make_addr(4,2,0), 1'b1, "tag4 present");
      do_read(make_addr(1,2,0), 1'b0, "tag1 was EVICTED (miss)");

      $display("\n================ TEST 4: write-allocate + dirty write-back, set 3 =============");
      // Write to a line not present -> write miss -> allocate (fetch) -> write.
      do_write(make_addr(0,3,0), 32'hDEAD_BEEF, 1'b0, "write-alloc tag0 set3");
      // Read it back -> hit, returns the written word.
      do_read(make_addr(0,3,0), 1'b1, "read back written word");
      if (last_cdout === 32'hDEAD_BEEF) begin
         pass_count++; $display("  [PASS] written value read back = %08h", last_cdout);
      end else begin
         fail_count++; $display("  [FAIL] read back = %08h (exp DEADBEEF)", last_cdout);
      end
      // Fill the rest of set 3 then force eviction of the dirty line.
      do_write(make_addr(1,3,0), 32'h1111_1111, 1'b0, "write-alloc tag1 set3");
      do_write(make_addr(2,3,0), 32'h2222_2222, 1'b0, "write-alloc tag2 set3");
      do_write(make_addr(3,3,0), 32'h3333_3333, 1'b0, "write-alloc tag3 set3");
      // tag0 (DEADBEEF) is LRU and dirty -> next insert must write it back.
      $display("  -- inserting tag4: expect a WRITE-BACK of the dirty LRU line --");
      do_read(make_addr(4,3,0), 1'b0, "insert tag4 -> writeback dirty");

      wait_cycles(2);

      $display("\n================================ SUMMARY ======================================");
      $display("  PASS = %0d   FAIL = %0d", pass_count, fail_count);
      if (fail_count == 0)
         $display("  ALL TESTS PASSED");
      else
         $display("  *** THERE WERE FAILURES ***");
      $display("===============================================================================\n");

      $finish;
   end

endmodule
