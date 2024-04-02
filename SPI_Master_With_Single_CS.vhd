-------------------------------------------------------------------------------
-- Engineer: siawash
--
-- Description: SPI (Serial Peripheral Interface) Master
--              With single chip-select (AKA Slave Select) capability
--
--              Supports arbitrary length byte transfers.
-- 
--              Instantiates a SPI Master and adds single CS.
--              If multiple CS signals are needed, will need to use different
--              module, OR multiplex the CS from this at a higher level.
--
-- Note:        i_Clk must be at least 2x faster than i_SPI_Clk
--
-- Parameters:  SPI_MODE, can be 0, 1, 2, or 3.  See above.
--              Can be configured in one of 4 modes:
--              Mode | Clock Polarity (CPOL/CKP) | Clock Phase (CPHA)
--               0   |             0             |        0
--               1   |             0             |        1
--               2   |             1             |        0
--               3   |             1             |        1
--
--              CLKS_PER_HALF_BIT - Sets frequency of o_SPI_Clk.  o_SPI_Clk is
--              derived from i_Clk.  Set to integer number of clocks for each
--              half-bit of SPI data.  E.g. 100 MHz i_Clk, CLKS_PER_HALF_BIT = 2
--              would create o_SPI_CLK of 25 MHz.  Must be >= 2
--
--				when Chip-Selct(CS) is means IDLE when is low mean active
--
--              MAX_BYTES_PER_CS - Set to the maximum number of bytes that
--              will be sent during a single CS-low pulse.
-- 
--              CS_INACTIVE_CLKS - Sets the amount of time in clock cycles to
--              hold the state of Chip-Selct high (inactive) before next 
--              command be allowed on the line.  Useful if chip requires some
--              time when CS is high between trasnfers.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity SPI_Master_With_Single_CS is
  generic (
    SPI_MODE          : integer := 0;
    CLKS_PER_HALF_BIT : integer := 2;
    MAX_BYTES_PER_CS  : integer := 2;
    CS_INACTIVE_CLKS  : integer := 1
    );
  port (
   -- Control/Data Signals,
   i_Rst_L : in std_logic;     -- FPGA Reset
   i_Clk   : in std_logic;     -- FPGA Clock
   
   -- TX (MOSI) Signals
   i_TX_Count : in  std_logic_vector(MAX_BYTES_PER_CS-1 downto 0);  -- # number of bytes sent per CS low (CS is active low)
   i_TX_Byte  : in  std_logic_vector(7 downto 0);  -- Byte to transmit on MOSI
   i_TX_DV    : in  std_logic;     -- Data Valid Pulse with i_TX_Byte
   o_TX_Ready : out std_logic;     -- Transmit Ready for next byte
   
   -- RX (MISO) Signals
   o_RX_Count : inout std_logic_vector(MAX_BYTES_PER_CS-1 downto 0);  -- Index RX byte (number of bytes recived per CS low)
   o_RX_DV    : inout std_logic;  -- Data Valid pulse (1 clock cycle)
   o_RX_Byte  : out std_logic_vector(7 downto 0);   -- Byte received on MISO

   -- SPI Interface
   o_SPI_Clk  : out std_logic;
   i_SPI_MISO : in  std_logic;
   o_SPI_MOSI : out std_logic;
   o_SPI_CS_n : out std_logic		-- tracking when main code(SPI_Master_With_Single_CS) compute is done 
   );
end entity SPI_Master_With_Single_CS;

architecture RTL of SPI_Master_With_Single_CS is

  type t_SM_CS is (IDLE, TRANSFER, CS_INACTIVE);

  signal r_SM_CS : t_SM_CS;											-- FSM
  signal r_CS_n : std_logic;										-- contol signal that tracking when main code(SPI_Master_With_Single_CS) compute is done
  signal r_CS_Inactive_Count : integer range 0 to CS_INACTIVE_CLKS;	-- inactive clk counter
  signal r_TX_Count : integer range 0 to MAX_BYTES_PER_CS + 1;		-- sent bytes counter (if we have n bytes to count, its count n-1 byte(more info below))
  signal w_Master_Ready : std_logic;								-- Transmit Ready for Byte

begin

  -- Instantiate Master
  SPI_Master_1 : entity work.SPI_Master
    generic map (
      SPI_MODE          => SPI_MODE,
      CLKS_PER_HALF_BIT => CLKS_PER_HALF_BIT)
    port map (
      -- Control/Data Signals,
      i_Rst_L    => i_Rst_L,            -- FPGA Reset
      i_Clk      => i_Clk,              -- FPGA Clock
      -- TX (MOSI) Signals
      i_TX_Byte  => i_TX_Byte,          -- Byte to transmit
      i_TX_DV    => i_TX_DV,            -- Data Valid pulse
      o_TX_Ready => w_Master_Ready,     -- Transmit Ready for Byte
      -- RX (MISO) Signals
      o_RX_DV    => o_RX_DV,            -- Data Valid pulse
      o_RX_Byte  => o_RX_Byte,          -- Byte received on MISO
      -- SPI Interface
      o_SPI_Clk  => o_SPI_Clk, 
      i_SPI_MISO => i_SPI_MISO,
      o_SPI_MOSI => o_SPI_MOSI
      );
  

  -- Purpose: Control CS line using State Machine
  SM_CS : process (i_Clk, i_Rst_L) is
  begin

    if rising_edge(i_Clk) then

      case r_SM_CS is
        when IDLE =>
          if r_CS_n = '1' and i_TX_DV = '1' then -- SPI is idle and FPGA sent byte to SPI so Start the transmission
            r_TX_Count <= to_integer(unsigned(i_TX_Count) - 1); -- Register TX Count
            r_CS_n     <= '0';       -- Drive CS low
            r_SM_CS    <= TRANSFER;   -- Transfer bytes
          end if;

        when TRANSFER =>
          -- Wait until SPI is done transferring do next thing
          if w_Master_Ready = '1' then  						-- SPI component sent a byte
            if r_TX_Count > 0 then								-- we still have byte to send
              if i_TX_DV = '1' then								-- we have a valid data from FPGA to SPI,ready to sent
                r_TX_Count <= r_TX_Count - 1;					-- while SPI component sending byte ,decrease byte counter
              end if;
            else
              r_CS_n              <= '1'; -- we done, so set CS high
              r_CS_Inactive_Count <= CS_INACTIVE_CLKS;			-- tell to inactive counter how much should wait before go to IDLE state  
              r_SM_CS             <= CS_INACTIVE;	-- assignment always takes 1 clk, so "r_TX_Count" can count number of bytes accuretly if we consider that
													-- for example we have two bytes to send:
													-- at first byte "r_TX_Count" counter count from 1 to 0 
													-- at second byte counter is done and assigning the next state to FSM will takes 1 clock to be done...
													-- witch  second byte will be done at the same time
            end if;
          end if;
          
        when CS_INACTIVE =>
          if r_CS_Inactive_Count > 0 then			--inactive counter counting to 0 then go to idle state
            r_CS_Inactive_Count <= r_CS_Inactive_Count - 1;
          else
            r_SM_CS <= IDLE;
          end if;

        when others => 	-- this state is error detector , we can add an error's control signal witch get high when FSM comes to this state
          r_CS_n  <= '1'; -- we done, so set CS high
          r_SM_CS <= IDLE;
      end case;
	    if i_Rst_L = '0' then							-- synchronous reset
			  r_SM_CS             <= IDLE;
			  r_CS_n              <= '1';   -- Resets the CS to high(CS is active low)
			  r_TX_Count          <= 0;
			  r_CS_Inactive_Count <= CS_INACTIVE_CLKS;
		end if;
    end if;
  end process SM_CS; 


  -- Purpose: Keep track of RX_Count
  RX_COUNT : process (i_Clk)
  begin
    if rising_edge(i_Clk) then
      if r_CS_n = '1' then
        o_RX_Count <= std_logic_vector(to_unsigned(0, o_RX_Count'length));  -- if CS is deactive , keep RX_counter 0
      elsif o_RX_DV = '1' then
        o_RX_Count <= std_logic_vector(unsigned(o_RX_Count) + 1); 			-- each time SPI component said:" i recived a byte" , count recived bytes
      end if;
    end if;
  end process RX_COUNT;

  o_SPI_CS_n <= r_CS_n;			-- set internal CS to output port

  o_TX_Ready <= '1' when i_TX_DV /= '1' and ((r_SM_CS = IDLE) or (r_SM_CS = TRANSFER and w_Master_Ready = '1' and r_TX_Count > 0)) else '0'; 
	-- main code "o_TX_Ready" will say im ready(IDLE) when : 
	-- 1- we dont have any new data from FPGA to SPI (i_TX_DV /= '1') + SPI's FSM is at IDLE state  			== end of the work of SPI
	-- 2- SPI's FSM is at TRANSFER state + SPI component said i sent a byte + we still have byte to send		== during work,every time a byte sent 
end architecture RTL;