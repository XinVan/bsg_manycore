/**
 *    bsg_manycore_tile_compute_array_mesh.v
 *
 */

`include "bsg_defines.v"

module bsg_manycore_tile_compute_array_mesh
  import bsg_manycore_pkg::*;
  import bsg_noc_pkg::*; // {P=0, W,E,N,S }
  #(`BSG_INV_PARAM(dmem_size_p ) // number of words in DMEM
    , `BSG_INV_PARAM(icache_entries_p ) // in words
    , `BSG_INV_PARAM(icache_tag_width_p )

    , `BSG_INV_PARAM(vcache_size_p ) // capacity per vcache in words
    , `BSG_INV_PARAM(vcache_block_size_in_words_p )
    , `BSG_INV_PARAM(vcache_sets_p )

    // change the default values from "inv" back to -1
    // since num_tiles_x_p and num_tiles_y_p will be used to define the size of 2D array
    // hetero_type_vec_p, they should be int by default to avoid tool crash during
    // DC synthesis (versions at least up to 2018.06)
    , `BSG_INV_PARAM(parameter int num_tiles_x_p)
    , `BSG_INV_PARAM(parameter int num_tiles_y_p)

    // This is used to define heterogeneous arrays. Each index defines
    // the type of an X/Y coordinate in the array. This is a vector of
    // num_tiles_x_p*num_tiles_y_p ints; type "0" is the
    // default. See bsg_manycore_hetero_socket.v for more types.
    , parameter int hetero_type_vec_p [0:((num_tiles_y_p-1)*num_tiles_x_p) - 1]  = '{default:0}

    // this is the addr width on the manycore network packet (word addr).
    // also known as endpoint physical address (EPA).
    , `BSG_INV_PARAM(addr_width_p )
    , `BSG_INV_PARAM(data_width_p ) // 32

    // Enable branch/jalr trace
    , branch_trace_en_p = 0

    // x-coordinate of the leftmost tiles
    // This can be set to 1 or greater to allow attaching accelerators on the left side.
    , start_x_cord_p = 0

    // y = 0                  top vcache
    // y = 1                  IO routers
    // y = num_tiles_y_p+1    bottom vcache
    , localparam y_cord_width_lp = `BSG_SAFE_CLOG2(num_tiles_y_p+2)

    // By default, x-coordinate is clog2(num_tiles_x_p), but it can be set to greater value to allow attaching accelerators on the side.
    , parameter x_cord_width_p = `BSG_SAFE_CLOG2(start_x_cord_p+num_tiles_x_p)

    , localparam link_sif_width_lp =
      `bsg_manycore_link_sif_width(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_lp)

    // The number of registers between the reset_i port and the reset sinks
    // Must be >= 1
    , parameter reset_depth_p = 3

    // enable debugging
    , debug_p = 0
  )
  (
    input clk_i
    , input reset_i

    // horizontal -- {E,W}
    , input [E:W][num_tiles_y_p-1:0][link_sif_width_lp-1:0] hor_link_sif_i
    , output [E:W][num_tiles_y_p-1:0][link_sif_width_lp-1:0] hor_link_sif_o

    // vertical -- {S,N}
    , input [S:N][num_tiles_x_p-1:0][link_sif_width_lp-1:0] ver_link_sif_i
    , output [S:N][num_tiles_x_p-1:0][link_sif_width_lp-1:0] ver_link_sif_o

    // IO-row p-ports
    , input [num_tiles_x_p-1:0][link_sif_width_lp-1:0] io_link_sif_i
    , output [num_tiles_x_p-1:0][link_sif_width_lp-1:0] io_link_sif_o
  );

   // synopsys translate_off
   initial
   begin
        int i,j;
       assert ((num_tiles_x_p > 0) && (num_tiles_y_p > 0))
           else $error("num_tiles_x_p and num_tiles_y_p must be positive constants");
        $display("## ----------------------------------------------------------------");
        $display("## MANYCORE HETERO TYPE CONFIGUREATIONS");
        $display("## ----------------------------------------------------------------");
        for(i=0; i < num_tiles_y_p-1; i++) begin
                $write("## ");
                for(j=0; j< num_tiles_x_p; j++) begin
                        $write("%0d,", hetero_type_vec_p[i * num_tiles_x_p + j]);
                end
                $write("\n");
        end
        $display("## ----------------------------------------------------------------");
   end
   // synopsys translate_on



  // Pipeline the reset. The bsg_manycore_tile has a single pipeline register
  // on reset already, so we only want to pipeline reset_depth_p-1 times.
  logic [num_tiles_y_p-2:0][num_tiles_x_p-1:0] tile_reset_r;
  logic [num_tiles_x_p-1:0] io_reset_r;

  bsg_dff_chain #(
    .width_p(num_tiles_x_p*(num_tiles_y_p-1))
    ,.num_stages_p(reset_depth_p-1)
  ) tile_reset (
    .clk_i(clk_i)
    ,.data_i({(num_tiles_x_p*(num_tiles_y_p-1)){reset_i}})
    ,.data_o(tile_reset_r)
  );
  
  bsg_dff_chain #(
    .width_p(num_tiles_x_p)
    ,.num_stages_p(reset_depth_p)
  ) io_reset (
    .clk_i(clk_i)
    ,.data_i({num_tiles_x_p{reset_i}})
    ,.data_o(io_reset_r)
  );


  // Instantiate tiles.
  `declare_bsg_manycore_link_sif_s(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_lp);
  bsg_manycore_link_sif_s [num_tiles_y_p-1:0][num_tiles_x_p-1:0][S:W] link_in;
  bsg_manycore_link_sif_s [num_tiles_y_p-1:0][num_tiles_x_p-1:0][S:W] link_out;
 

  for (genvar r = 2; r <= num_tiles_y_p; r++) begin: y
    for (genvar c = 0; c < num_tiles_x_p; c++) begin: x
      bsg_manycore_tile_mesh #(
        .dmem_size_p     (dmem_size_p)
        ,.vcache_size_p (vcache_size_p)
        ,.icache_entries_p(icache_entries_p)
        ,.icache_tag_width_p(icache_tag_width_p)
        ,.start_x_cord_p(start_x_cord_p)
        ,.x_cord_width_p(x_cord_width_p)
        ,.y_cord_width_p(y_cord_width_lp)
        ,.data_width_p(data_width_p)
        ,.addr_width_p(addr_width_p)
        ,.hetero_type_p( hetero_type_vec_p[(r-2) * num_tiles_x_p + c] )
        ,.debug_p(debug_p)
        ,.branch_trace_en_p(branch_trace_en_p)
        ,.num_tiles_x_p(num_tiles_x_p)
        ,.num_tiles_y_p(num_tiles_y_p)
        ,.vcache_block_size_in_words_p(vcache_block_size_in_words_p)
        ,.vcache_sets_p(vcache_sets_p)
      ) tile (
        .clk_i(clk_i)
        ,.reset_i(tile_reset_r[r-2][c])

        ,.link_i(link_in[r-1][c])
        ,.link_o(link_out[r-1][c])

        ,.my_x_i(x_cord_width_p'(c+start_x_cord_p))
        ,.my_y_i(y_cord_width_lp'(r))
      );
    end
  end


  // Instantiate IO routers.
  for (genvar c = 0; c < num_tiles_x_p; c=c+1) begin: io
    bsg_manycore_mesh_node #(
      .x_cord_width_p     (x_cord_width_p )
      ,.y_cord_width_p     (y_cord_width_lp )
      ,.data_width_p       (data_width_p    )
      ,.addr_width_p       (addr_width_p    )
    ) io_router (
      .clk_i    (clk_i      )
      ,.reset_i  (io_reset_r[c])
        
      ,.links_sif_i      ( link_in [0][ c ] )
      ,.links_sif_o      ( link_out[0][ c ] )

      ,.proc_link_sif_i  ( io_link_sif_i [ c ])
      ,.proc_link_sif_o  ( io_link_sif_o [ c ])
        
      // tile coordinates
      ,.my_x_i   ( x_cord_width_p'(c+start_x_cord_p))
      ,.my_y_i   ( y_cord_width_lp'(1))
   );
  end



  // stitch together all of the tiles into a mesh
  bsg_mesh_stitch #(
    .width_p(link_sif_width_lp)
    ,.x_max_p(num_tiles_x_p)
    ,.y_max_p(num_tiles_y_p)
  ) link (
    .outs_i(link_out)
    ,.ins_o(link_in)
    ,.hor_i(hor_link_sif_i)
    ,.hor_o(hor_link_sif_o)
    ,.ver_i(ver_link_sif_i)
    ,.ver_o(ver_link_sif_o)
  );


endmodule

`BSG_ABSTRACT_MODULE(bsg_manycore_tile_compute_array_mesh)
