/*
 * Copyright (c) 2026 Tu Nombre
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_breakout_vga (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock (25.175 MHz para VGA)
    input  wire       rst_n     // reset_n - low to reset
);

  // ui_in[0] = izquierda, ui_in[1] = derecha, ui_in[2] = lanzar / reiniciar

  // Sincronizador de botones (2 flip-flops)
  reg [2:0] s1, s2;
  always @(posedge clk) begin
    s1 <= ui_in[2:0];
    s2 <= s1;
  end

  // Senales internas
  wire [9:0]  hc, vc;
  wire        hsync, vsync, active, frame_tick;
  wire [1:0]  state, lives;
  wire [9:0]  px, bx, by;
  wire [31:0] bricks;
  wire [1:0]  r, g, b;

  // Temporizacion VGA 640x480@60
  breakout_vga_sync vga (
      .clk(clk),
      .rst_n(rst_n),
      .hc(hc),
      .vc(vc),
      .hsync(hsync),
      .vsync(vsync),
      .active(active),
      .frame_tick(frame_tick)
  );

  // Logica del juego
  breakout_game game (
      .clk(clk),
      .rst_n(rst_n),
      .btn_l(s2[0]),
      .btn_r(s2[1]),
      .btn_go(s2[2]),
      .frame_tick(frame_tick),
      .state(state),
      .px(px),
      .bx(bx),
      .by(by),
      .bricks(bricks),
      .lives(lives)
  );

  // Dibujado de pantalla
  breakout_render render (
      .hc(hc),
      .vc(vc),
      .active(active),
      .state(state),
      .px(px),
      .bx(bx),
      .by(by),
      .bricks(bricks),
      .lives(lives),
      .r(r),
      .g(g),
      .b(b)
  );

  // Salidas registradas -> pinout TinyVGA PMOD
  reg hs_q, vs_q;
  reg [1:0] r_q, g_q, b_q;
  always @(posedge clk) begin
    hs_q <= hsync;
    vs_q <= vsync;
    r_q  <= r;
    g_q  <= g;
    b_q  <= b;
  end

  // Assign the VGA signals to the output
  assign uo_out = {hs_q, b_q[0], g_q[0], r_q[0], vs_q, b_q[1], g_q[1], r_q[1]};

  // All other output pins must be assigned. If not used, assign to 0.
  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, ui_in[7:3], 1'b0};

endmodule


// ---------------------------------------------------------------
// Generador de sincronia VGA 640x480 @ 60 Hz
// ---------------------------------------------------------------
module breakout_vga_sync (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [9:0] hc,
    output reg  [9:0] vc,
    output wire       hsync,
    output wire       vsync,
    output wire       active,
    output wire       frame_tick   // 1 pulso por cuadro (inicio del blanking)
);
  always @(posedge clk) begin
    if (!rst_n) begin
      hc <= 10'd0;
      vc <= 10'd0;
    end else if (hc == 10'd799) begin
      hc <= 10'd0;
      vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
    end else begin
      hc <= hc + 10'd1;
    end
  end

  assign hsync      = ~((hc >= 10'd656) && (hc < 10'd752));
  assign vsync      = ~((vc >= 10'd490) && (vc < 10'd492));
  assign active     = (hc < 10'd640) && (vc < 10'd480);
  assign frame_tick = (hc == 10'd0) && (vc == 10'd480);
endmodule


// ---------------------------------------------------------------
// Logica del juego: paleta, pelota, ladrillos y vidas
// ---------------------------------------------------------------
module breakout_game (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        btn_l,
    input  wire        btn_r,
    input  wire        btn_go,
    input  wire        frame_tick,
    output reg  [1:0]  state,    // 0 = saque, 1 = jugando, 2 = game over
    output reg  [9:0]  px,       // x de la paleta (64 px de ancho)
    output reg  [9:0]  bx,       // x de la pelota (8x8)
    output reg  [9:0]  by,       // y de la pelota
    output reg  [31:0] bricks,   // 1 = ladrillo vivo
    output reg  [1:0]  lives
);
  localparam [1:0] S_SERVE = 2'd0, S_PLAY = 2'd1, S_OVER = 2'd2;

  reg       dx, dy;       // 1 = derecha / abajo
  reg [7:0] fcnt;         // contador de cuadros (direccion aleatoria del saque)
  reg       go_prev;

  // Zona de ladrillos: x 64..575 (8 columnas de 64), y 64..127 (4 filas de 16)
  function brick_zone(input [9:0] x, input [9:0] y);
    brick_zone = (x[9:6] != 4'd0) && (x[9:6] <= 4'd8) && (y[9:6] == 4'd1);
  endfunction

  function [4:0] brick_index(input [9:0] x, input [9:0] y);
    reg [3:0] c;
    begin
      c = x[9:6] - 4'd1;
      brick_index = {y[5:4], c[2:0]};
    end
  endfunction

  // Temporales del update
  reg [9:0] npx, nx, ny;
  reg       ndx, ndy, lost;

  always @(posedge clk) begin
    if (!rst_n) begin
      state   <= S_SERVE;
      px      <= 10'd288;
      bx      <= 10'd316;
      by      <= 10'd440;
      dx      <= 1'b1;
      dy      <= 1'b0;
      bricks  <= 32'hFFFF_FFFF;
      lives   <= 2'd3;
      fcnt    <= 8'd0;
      go_prev <= 1'b0;
    end else if (frame_tick) begin
      fcnt    <= fcnt + 8'd1;
      go_prev <= btn_go;

      // Movimiento de la paleta (6 px por cuadro)
      npx = px;
      if (state != S_OVER) begin
        if (btn_l && !btn_r)
          npx = (px >= 10'd70) ? px - 10'd6 : 10'd64;
        else if (btn_r && !btn_l)
          npx = (px <= 10'd506) ? px + 10'd6 : 10'd512;
      end
      px <= npx;

      // Nivel completado: rellenar ladrillos
      if (bricks == 32'd0) bricks <= 32'hFFFF_FFFF;

      case (state)
        // Pelota pegada a la paleta hasta presionar "lanzar"
        S_SERVE: begin
          bx <= npx + 10'd28;
          by <= 10'd440;
          dy <= 1'b0;
          if (btn_go && !go_prev) begin
            dx    <= fcnt[0];
            state <= S_PLAY;
          end
        end

        S_PLAY: begin
          nx   = dx ? bx + 10'd4 : bx - 10'd4;
          ny   = dy ? by + 10'd4 : by - 10'd4;
          ndx  = dx;
          ndy  = dy;
          lost = 1'b0;

          // Paredes laterales y techo
          if (nx < 10'd64)       begin nx = 10'd64;  ndx = 1'b1; end
          else if (nx > 10'd568) begin nx = 10'd568; ndx = 1'b0; end
          if (ny < 10'd56)       begin ny = 10'd56;  ndy = 1'b1; end

          // Rebote en la paleta (el angulo depende de donde pega)
          if (dy && (ny >= 10'd440) && (ny < 10'd456) &&
              (nx + 10'd8 > npx) && (nx < npx + 10'd64)) begin
            ny  = 10'd440;
            ndy = 1'b0;
            if      (nx + 10'd4 < npx + 10'd21) ndx = 1'b0;
            else if (nx + 10'd4 > npx + 10'd42) ndx = 1'b1;
          end

          // Choque con ladrillo
          if (brick_zone(nx + 10'd4, ny + 10'd4) &&
              bricks[brick_index(nx + 10'd4, ny + 10'd4)]) begin
            bricks[brick_index(nx + 10'd4, ny + 10'd4)] <= 1'b0;
            ndy = ~ndy;
          end

          // Se cayo la pelota
          if (ny >= 10'd480) lost = 1'b1;

          if (lost) begin
            if (lives == 2'd1) state <= S_OVER;
            else               state <= S_SERVE;
            lives <= lives - 2'd1;
          end else begin
            bx <= nx;
            by <= ny;
            dx <= ndx;
            dy <= ndy;
          end
        end

        // Game over: "lanzar" reinicia
        default: begin
          if (btn_go && !go_prev) begin
            state  <= S_SERVE;
            lives  <= 2'd3;
            bricks <= 32'hFFFF_FFFF;
          end
        end
      endcase
    end
  end
endmodule


// ---------------------------------------------------------------
// Dibujado: calcula el color del pixel actual
// ---------------------------------------------------------------
module breakout_render (
    input  wire [9:0]  hc,
    input  wire [9:0]  vc,
    input  wire        active,
    input  wire [1:0]  state,
    input  wire [9:0]  px,
    input  wire [9:0]  bx,
    input  wire [9:0]  by,
    input  wire [31:0] bricks,
    input  wire [1:0]  lives,
    output reg  [1:0]  r,
    output reg  [1:0]  g,
    output reg  [1:0]  b
);
  function brick_zone(input [9:0] x, input [9:0] y);
    brick_zone = (x[9:6] != 4'd0) && (x[9:6] <= 4'd8) && (y[9:6] == 4'd1);
  endfunction

  function [4:0] brick_index(input [9:0] x, input [9:0] y);
    reg [3:0] c;
    begin
      c = x[9:6] - 4'd1;
      brick_index = {y[5:4], c[2:0]};
    end
  endfunction

  wire over    = (state == 2'd2);
  wire playing = ~over;

  wire in_ball   = playing && (hc >= bx) && (hc < bx + 10'd8) &&
                   (vc >= by) && (vc < by + 10'd8);
  wire in_paddle = playing && (vc >= 10'd448) && (vc < 10'd456) &&
                   (hc >= px) && (hc < px + 10'd64);
  wire in_wall   = ((vc >= 10'd48) && (vc < 10'd56) && (hc >= 10'd56) && (hc < 10'd584)) ||
                   ((vc >= 10'd48) &&
                    (((hc >= 10'd56) && (hc < 10'd64)) || ((hc >= 10'd576) && (hc < 10'd584))));
  wire in_brick  = brick_zone(hc, vc) && bricks[brick_index(hc, vc)] &&
                   (hc[5:0] < 6'd62) && (vc[3:0] < 4'd14);

  wire l0 = (hc >= 10'd64)  && (hc < 10'd80);
  wire l1 = (hc >= 10'd88)  && (hc < 10'd104);
  wire l2 = (hc >= 10'd112) && (hc < 10'd128);
  wire in_lives = (vc >= 10'd16) && (vc < 10'd32) &&
                  (((lives >= 2'd1) && l0) || ((lives >= 2'd2) && l1) || ((lives >= 2'd3) && l2));

  always @* begin
    r = 2'd0; g = 2'd0; b = 2'd0;
    if (active) begin
      if (over) r = 2'd1; else b = 2'd1;                 // fondo
      if (in_wall)  begin r = 2'd2; g = 2'd2; b = 2'd2; end
      if (in_lives) begin r = 2'd3; g = 2'd3; b = 2'd0; end
      if (in_brick) begin
        case (vc[5:4])
          2'd0: begin r = 2'd3; g = 2'd0; b = 2'd0; end  // rojo
          2'd1: begin r = 2'd3; g = 2'd1; b = 2'd0; end  // naranja
          2'd2: begin r = 2'd0; g = 2'd3; b = 2'd0; end  // verde
          default: begin r = 2'd0; g = 2'd1; b = 2'd3; end // azul
        endcase
      end
      if (in_paddle) begin r = 2'd0; g = 2'd3; b = 2'd3; end
      if (in_ball)   begin r = 2'd3; g = 2'd3; b = 2'd3; end
    end
  end
endmodule
