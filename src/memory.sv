`include "defs.svh"
`timescale 1ns/1ps
module memory
  #(parameter ADDRESS_WIDTH = 18,
    parameter BLOCK_SIZE = 256,
    parameter FILE = ""
    )
   (
    input logic clock,
    input logic [BLOCK_SIZE - 1:0] din,
    input logic [ADDRESS_WIDTH - 1:0] address,
    input logic rden,
    input logic wren,
    output logic [BLOCK_SIZE -1:0] dout
    );

   localparam DEPTH = 2 ** 18;
   
   
   reg [BLOCK_SIZE-1:0] mem [0:DEPTH-1];


   integer              i;

   initial
     begin
        //read file content
        if (FILE != "")
          $readmemh(FILE, mem);
        else
          for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {BLOCK_SIZE{1'b0}};
     end

   always_ff @(posedge clock)
     begin
        if (wren)
          mem[address] <= din;
     end

   always_ff @(posedge clock)
     begin
        if (rden)
          dout <= mem[address];
     end

endmodule // memory

   
       
        
   
   
