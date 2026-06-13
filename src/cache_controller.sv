`include "defs.svh"

`timescale 1ns/1ps

module cache_controller
  #(
    parameter BLOCK_SIZE = 256,
    parameter ADDRESS_WIDTH = 21,
    parameter INDEX_WIDTH = 10,
    parameter TAG_WIDTH = 8,
    parameter OFFSET_WIDTH = 3,
    parameter WORD_SIZE = 32,
    parameter NBLOCKS = 1024
)
   (
    input logic                                  clock,
    input logic                                  rst_n,
    input logic [ADDRESS_WIDTH - 1:0]            caddress,
    input logic [WORD_SIZE - 1:0]                cdin,
    input logic [BLOCK_SIZE - 1:0]               mdin,
    input logic                                  rden,
    input logic                                  wren,
    output logic                                 hit,
    output logic [WORD_SIZE - 1:0]               cdout,
    output logic [BLOCK_SIZE - 1:0]              mdout,
    output logic [TAG_WIDTH + INDEX_WIDTH - 1:0] maddress,
    output logic                                 mrden,
    output logic                                 mwren
    );

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

   localparam TAG_MSB           = 20;
   localparam TAG_LSB           = 13;
   localparam INDEX_MSB         = 12;
   localparam INDEX_LSB         = 3;
   localparam BLOCK_OFFSET_MSB  = 2;
   localparam BLOCK_OFFSET_LSB  = 0;

   logic                         cache_valid[0:NBLOCKS - 1];
   logic                         cache_dirty[0:NBLOCKS - 1];
   logic [TAG_WIDTH - 1:0]       cache_tag[0:NBLOCKS - 1];
   logic [BLOCK_SIZE - 1:0]      cache_mem[0:NBLOCKS - 1];

   logic [ADDRESS_WIDTH - 1:0]   req_addr;
   logic                         req_read;
   logic                         req_write;
   logic [WORD_SIZE - 1:0]       req_wdata;

   logic [ADDRESS_WIDTH - 1:0]   active_addr;
   logic [INDEX_WIDTH - 1:0]     active_index;
   logic [TAG_WIDTH - 1:0]       active_tag;
   logic [OFFSET_WIDTH - 1:0]    active_offset;

   logic                         lookup_hit;
   logic [WORD_SIZE - 1:0]       read_data;

   function automatic logic [WORD_SIZE - 1:0] block_get_word(
      input logic [BLOCK_SIZE - 1:0] block,
      input logic [OFFSET_WIDTH - 1:0] word_offset
   );
      return block[32 * word_offset +: WORD_SIZE];
   endfunction

   function automatic logic [BLOCK_SIZE - 1:0] block_set_word(
      input logic [BLOCK_SIZE - 1:0] block,
      input logic [OFFSET_WIDTH - 1:0] word_offset,
      input logic [WORD_SIZE - 1:0] word
   );
      logic [BLOCK_SIZE - 1:0] result;
      result = block;
      result[32 * word_offset +: WORD_SIZE] = word;
      return result;
   endfunction

   assign active_addr = (current_state == STATE_IDLE) ? caddress : req_addr;
   assign active_index   = active_addr[INDEX_MSB:INDEX_LSB];
   assign active_tag     = active_addr[TAG_MSB:TAG_LSB];
   assign active_offset  = active_addr[BLOCK_OFFSET_MSB:BLOCK_OFFSET_LSB];

   assign lookup_hit = cache_valid[active_index]
                       && (cache_tag[active_index] == active_tag);
   assign hit = lookup_hit;

   assign read_data = block_get_word(cache_mem[active_index], active_offset);

   always_comb begin
      next_state = current_state;
      cdout    = '0;
      mdout    = '0;
      maddress = '0;
      mrden    = 1'b0;
      mwren    = 1'b0;

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
            cdout = read_data;
            next_state = STATE_IDLE;
         end

         STATE_READ_MISS: begin
            if (cache_dirty[active_index])
               next_state = STATE_REPLACE;
            else
               next_state = STATE_FETCH;
         end

         STATE_WRITE_MISS: begin
            if (cache_dirty[active_index])
               next_state = STATE_REPLACE;
            else
               next_state = STATE_FETCH;
         end

         STATE_REPLACE: begin
            mwren    = 1'b1;
            maddress = {cache_tag[active_index], active_index};
            mdout    = cache_mem[active_index];
            next_state = STATE_FETCH;
         end

         STATE_FETCH: begin
            mrden    = 1'b1;
            maddress = {active_tag, active_index};
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

   integer k;

   initial begin
      for (k = 0; k < NBLOCKS; k = k + 1) begin
         cache_valid[k] = 1'b0;
         cache_dirty[k] = 1'b0;
         cache_tag[k]   = '0;
         cache_mem[k]   = '0;
      end
   end

   always_ff @(posedge clock) begin
      if (!rst_n) begin
         current_state <= STATE_IDLE;
         req_read      <= 1'b0;
         req_write     <= 1'b0;
         for (k = 0; k < NBLOCKS; k = k + 1) begin
            cache_valid[k] <= 1'b0;
            cache_dirty[k] <= 1'b0;
            cache_tag[k]   <= '0;
            cache_mem[k]   <= '0;
         end
      end else begin
         current_state <= next_state;

         if (current_state == STATE_IDLE && (rden || wren)) begin
            req_addr  <= caddress;
            req_read  <= rden;
            req_write <= wren;
            req_wdata <= cdin;
         end

         if (current_state == STATE_FILL) begin
            cache_mem[active_index]   <= mdin;
            cache_tag[active_index]   <= active_tag;
            cache_valid[active_index] <= 1'b1;
            cache_dirty[active_index] <= 1'b0;
         end

         if (current_state == STATE_WRITE_HIT) begin
            cache_mem[active_index]   <= block_set_word(
               cache_mem[active_index], active_offset, req_wdata
            );
            cache_dirty[active_index] <= 1'b1;
         end
      end
   end

endmodule
