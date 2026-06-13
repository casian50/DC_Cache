`timescale 1ns/1ps

//============================================================================
//  32 KiB, 4-way set-associative cache
//  - 8 words / block  (256-bit block)
//  - 32-bit words
//  - 8 MiB main memory, word addressable (21-bit word address)
//  - write-back, write-allocate
//  - LRU replacement policy (true LRU, counter based)
//
//  Address breakdown (21 bits):
//     | TAG  [20:11] (10b) | INDEX [10:3] (8b) | OFFSET [2:0] (3b) |
//
//  Geometry:
//     32 KiB / (8 words * 4 B) = 1024 blocks
//     1024 blocks / 4 ways     = 256 sets  -> INDEX_WIDTH = 8
//============================================================================

module cache_controller
  #(
    parameter BLOCK_SIZE    = 256,  // bits (8 words * 32 bits)
    parameter ADDRESS_WIDTH = 21,   // bits (10 tag + 8 index + 3 offset)
    parameter INDEX_WIDTH   = 8,    // bits -> 256 sets
    parameter TAG_WIDTH     = 10,   // bits
    parameter OFFSET_WIDTH  = 3,    // bits -> 8 words/block
    parameter WORD_SIZE     = 32,   // bits
    parameter NWAYS         = 4,    // 4-way set associative
    parameter NSETS         = 256   // 2^INDEX_WIDTH
)
   (
    input  logic                                  clock,
    input  logic                                  rst_n,
    input  logic [ADDRESS_WIDTH - 1:0]            caddress,
    input  logic [WORD_SIZE - 1:0]                cdin,
    input  logic [BLOCK_SIZE - 1:0]               mdin,
    input  logic                                  rden,
    input  logic                                  wren,
    output logic                                  hit,
    output logic [WORD_SIZE - 1:0]                cdout,
    output logic [BLOCK_SIZE - 1:0]               mdout,
    output logic [TAG_WIDTH + INDEX_WIDTH - 1:0]  maddress,
    output logic                                  mrden,
    output logic                                  mwren
    );

   //--------------------------------------------------------------------------
   // Derived local parameters
   //--------------------------------------------------------------------------
   localparam WAY_WIDTH = $clog2(NWAYS);   // 2 bits for 4 ways
   localparam LRU_MAX   = NWAYS - 1;       // MRU rank value (3)

   typedef enum logic [2:0] {
      STATE_IDLE,
      STATE_READ_HIT,
      STATE_READ_MISS,
      STATE_WRITE_HIT,
      STATE_WRITE_MISS,
      STATE_REPLACE,
      STATE_FETCH,
      STATE_FILL
   } state_t;

   state_t current_state, next_state;

   //--------------------------------------------------------------------------
   // Address field positions
   //--------------------------------------------------------------------------
   localparam TAG_MSB           = 20;
   localparam TAG_LSB           = 11;
   localparam INDEX_MSB         = 10;
   localparam INDEX_LSB         = 3;
   localparam BLOCK_OFFSET_MSB  = 2;
   localparam BLOCK_OFFSET_LSB  = 0;

   //--------------------------------------------------------------------------
   // Cache storage: organised as [set][way]
   //--------------------------------------------------------------------------
   logic                    cache_valid [0:NSETS - 1][0:NWAYS - 1];
   logic                    cache_dirty [0:NSETS - 1][0:NWAYS - 1];
   logic [TAG_WIDTH - 1:0]  cache_tag   [0:NSETS - 1][0:NWAYS - 1];
   logic [BLOCK_SIZE - 1:0] cache_mem   [0:NSETS - 1][0:NWAYS - 1];
   // LRU rank per way: LRU_MAX = most-recently-used, 0 = least-recently-used.
   logic [WAY_WIDTH - 1:0]  lru_cnt     [0:NSETS - 1][0:NWAYS - 1];

   //--------------------------------------------------------------------------
   // Latched request
   //--------------------------------------------------------------------------
   logic [ADDRESS_WIDTH - 1:0]  req_addr;
   logic                        req_read;
   logic                        req_write;
   logic [WORD_SIZE - 1:0]      req_wdata;
   logic [WAY_WIDTH - 1:0]      req_way;     // way being serviced this transaction

   //--------------------------------------------------------------------------
   // Active (combinational) request view
   //--------------------------------------------------------------------------
   logic [ADDRESS_WIDTH - 1:0]  active_addr;
   logic [INDEX_WIDTH - 1:0]    active_index;
   logic [TAG_WIDTH - 1:0]      active_tag;
   logic [OFFSET_WIDTH - 1:0]   active_offset;
   logic [WAY_WIDTH - 1:0]      active_way;

   logic                        lookup_hit;
   logic [WAY_WIDTH - 1:0]      hit_way;
   logic [WAY_WIDTH - 1:0]      victim_way;
   logic [WAY_WIDTH - 1:0]      access_way;  // way chosen for this access
   logic [WORD_SIZE - 1:0]      read_data;

   //--------------------------------------------------------------------------
   // Block <-> word helpers
   //--------------------------------------------------------------------------
   function automatic logic [WORD_SIZE - 1:0] block_get_word(
      input logic [BLOCK_SIZE - 1:0]   block,
      input logic [OFFSET_WIDTH - 1:0] word_offset
   );
      return block[WORD_SIZE * word_offset +: WORD_SIZE];
   endfunction

   function automatic logic [BLOCK_SIZE - 1:0] block_set_word(
      input logic [BLOCK_SIZE - 1:0]   block,
      input logic [OFFSET_WIDTH - 1:0] word_offset,
      input logic [WORD_SIZE - 1:0]    word
   );
      logic [BLOCK_SIZE - 1:0] result;
      result = block;
      result[WORD_SIZE * word_offset +: WORD_SIZE] = word;
      return result;
   endfunction

   //--------------------------------------------------------------------------
   // Address decode
   //--------------------------------------------------------------------------
   assign active_addr    = (current_state == STATE_IDLE) ? caddress : req_addr;
   assign active_index   = active_addr[INDEX_MSB:INDEX_LSB];
   assign active_tag     = active_addr[TAG_MSB:TAG_LSB];
   assign active_offset  = active_addr[BLOCK_OFFSET_MSB:BLOCK_OFFSET_LSB];

   //--------------------------------------------------------------------------
   // Associative lookup across the 4 ways of the selected set
   //--------------------------------------------------------------------------
   integer wi;
   always_comb begin
      lookup_hit = 1'b0;
      hit_way    = '0;
      for (wi = 0; wi < NWAYS; wi = wi + 1) begin
         if (cache_valid[active_index][wi] &&
             (cache_tag[active_index][wi] == active_tag)) begin
            lookup_hit = 1'b1;
            hit_way    = WAY_WIDTH'(wi);
         end
      end
   end

   //--------------------------------------------------------------------------
   // Victim selection: first an invalid way if any, otherwise the LRU way
   // (the way whose LRU rank is 0).
   //--------------------------------------------------------------------------
   integer vj;
   logic   found_invalid;
   always_comb begin
      victim_way    = '0;
      found_invalid = 1'b0;
      for (vj = 0; vj < NWAYS; vj = vj + 1) begin
         if (!found_invalid && !cache_valid[active_index][vj]) begin
            victim_way    = WAY_WIDTH'(vj);
            found_invalid = 1'b1;
         end
      end
      if (!found_invalid) begin
         for (vj = 0; vj < NWAYS; vj = vj + 1) begin
            if (lru_cnt[active_index][vj] == '0)
               victim_way = WAY_WIDTH'(vj);
         end
      end
   end

   // Way used for the current access: the hit way if hit, else the victim.
   assign access_way = lookup_hit ? hit_way : victim_way;
   // During a multi-cycle transaction we use the latched way.
   assign active_way = (current_state == STATE_IDLE) ? access_way : req_way;

   assign hit       = lookup_hit;
   assign read_data = block_get_word(cache_mem[active_index][active_way], active_offset);

   //--------------------------------------------------------------------------
   // Next-state / output logic
   //--------------------------------------------------------------------------
   always_comb begin
      next_state = current_state;
      cdout      = '0;
      mdout      = '0;
      maddress   = '0;
      mrden      = 1'b0;
      mwren      = 1'b0;

      case (current_state)
         STATE_IDLE: begin
            if (rden && lookup_hit)
               next_state = STATE_READ_HIT;
            else if (rden)
               next_state = STATE_READ_MISS;
            else if (wren && lookup_hit)
               next_state = STATE_WRITE_HIT;
            else if (wren)
               next_state = STATE_WRITE_MISS;
         end

         STATE_READ_HIT: begin
            cdout      = read_data;
            next_state = STATE_IDLE;
         end

         // Write-allocate: a miss must first bring the block in.
         // If the victim line is dirty it has to be written back first.
         STATE_READ_MISS: begin
            if (cache_dirty[active_index][active_way])
               next_state = STATE_REPLACE;
            else
               next_state = STATE_FETCH;
         end

         STATE_WRITE_MISS: begin
            if (cache_dirty[active_index][active_way])
               next_state = STATE_REPLACE;
            else
               next_state = STATE_FETCH;
         end

         // Write-back of the dirty victim line to main memory.
         STATE_REPLACE: begin
            mwren      = 1'b1;
            maddress   = {cache_tag[active_index][active_way], active_index};
            mdout      = cache_mem[active_index][active_way];
            next_state = STATE_FETCH;
         end

         // Fetch the requested block from main memory.
         STATE_FETCH: begin
            mrden      = 1'b1;
            maddress   = {active_tag, active_index};
            next_state = STATE_FILL;
         end

         STATE_FILL: begin
            if (req_read)
               next_state = STATE_READ_HIT;
            else if (req_write)
               next_state = STATE_WRITE_HIT;
            else
               next_state = STATE_IDLE;
         end

         STATE_WRITE_HIT: begin
            next_state = STATE_IDLE;
         end

         default: begin
            next_state = STATE_IDLE;
         end
      endcase
   end

   //--------------------------------------------------------------------------
   // Power-up initialisation (for simulation)
   //--------------------------------------------------------------------------
   integer si, ki;
   initial begin
      for (si = 0; si < NSETS; si = si + 1)
         for (ki = 0; ki < NWAYS; ki = ki + 1) begin
            cache_valid[si][ki] = 1'b0;
            cache_dirty[si][ki] = 1'b0;
            cache_tag[si][ki]   = '0;
            cache_mem[si][ki]   = '0;
            lru_cnt[si][ki]     = WAY_WIDTH'(ki); // distinct initial ranks
         end
   end

   //--------------------------------------------------------------------------
   // Sequential update
   //--------------------------------------------------------------------------
   integer su, ku;
   always_ff @(posedge clock) begin
      if (!rst_n) begin
         current_state <= STATE_IDLE;
         req_read      <= 1'b0;
         req_write     <= 1'b0;
         for (su = 0; su < NSETS; su = su + 1)
            for (ku = 0; ku < NWAYS; ku = ku + 1) begin
               cache_valid[su][ku] <= 1'b0;
               cache_dirty[su][ku] <= 1'b0;
               cache_tag[su][ku]   <= '0;
               cache_mem[su][ku]   <= '0;
               lru_cnt[su][ku]     <= WAY_WIDTH'(ku);
            end
      end else begin
         current_state <= next_state;

         // Latch the incoming request and the way it will use.
         if (current_state == STATE_IDLE && (rden || wren)) begin
            req_addr  <= caddress;
            req_read  <= rden;
            req_write <= wren;
            req_wdata <= cdin;
            req_way   <= access_way;   // hit_way on hit, victim_way on miss
         end

         // Block arrives from memory -> install in the chosen (victim) way.
         if (current_state == STATE_FILL) begin
            cache_mem[active_index][req_way]   <= mdin;
            cache_tag[active_index][req_way]   <= active_tag;
            cache_valid[active_index][req_way] <= 1'b1;
            cache_dirty[active_index][req_way] <= 1'b0;
         end

         // Commit the store on a write hit (also the post-allocate write).
         if (current_state == STATE_WRITE_HIT) begin
            cache_mem[active_index][active_way] <=
               block_set_word(cache_mem[active_index][active_way],
                              active_offset, req_wdata);
            cache_dirty[active_index][active_way] <= 1'b1;
         end

         // LRU update: on any completed access the touched way becomes MRU.
         if (current_state == STATE_READ_HIT ||
             current_state == STATE_WRITE_HIT) begin
            for (ku = 0; ku < NWAYS; ku = ku + 1) begin
               if (lru_cnt[active_index][ku] > lru_cnt[active_index][active_way])
                  lru_cnt[active_index][ku] <= lru_cnt[active_index][ku] - 1'b1;
            end
            lru_cnt[active_index][active_way] <= WAY_WIDTH'(LRU_MAX);
         end
      end
   end

endmodule
