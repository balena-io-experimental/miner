%% @doc This module provides time-on-air regulatory compliance for the
%% EU868 and US915 ISM bands.
%%
%% This module does not interface with hardware or provide any
%% transmission capabilities itself. Instead, the API provides its
%% core functionality through `track_sent/4', `can_send/4', and
%% `time_on_air/6'.
-module(miner_lora_throttle).

-export([
    can_send/4,
    dwell_time/3,
    dwell_time_period/1,
    max_dwell_time/1,
    new/1,
    time_on_air/6,
    track_sent/9,
    track_sent/4
]).

-export_type([
    region/0,
    handle/0
]).

-record(sent_packet, {
    sent_at :: number(),
    time_on_air :: number(),
    frequency :: number()
}).

-type region() :: 'EU868' | 'US915'.

-opaque handle() :: {region(), list(#sent_packet{})}.

%% @doc Time over which we keep sent packet statistics for duty-cycle
%% limited regions (EU868).
%%
%% In order to calculate duty cycle, we track every single
%% transmission 'now' and the previous DUTY_CYCLE_PERIOD_MS of
%% time. Note that 'now' is always changing and that transmissions
%% older than DUTY_CYCLE_PERIOD_MS are only untracked when updating
%% state or calculating duty-cycle.
-define(DUTY_CYCLE_PERIOD_MS, 3600000).

%% Maximum time on air for dell-time limited regions (US915).
%%
%% See 47 CFR 15.247.
-define(MAX_DWELL_TIME_MS, 400).

%% Time over which enforce MAX_DWELL_TIME_MS.
-define(DWELL_TIME_PERIOD_MS, 20000).

%% Updates Handle with time-on-air information.
%%
%% This function does not send/transmit itself.
-spec track_sent(
    Handle :: handle(),
    SentAt :: number(),
    Frequency :: number(),
    Bandwidth :: number(),
    SpreadingFactor :: integer(),
    CodeRate :: integer(),
    PreambleSymbols :: integer(),
    ExplicitHeader :: boolean(),
    PayloadLen :: integer()
) ->
    handle().
track_sent(
    Handle,
    SentAt,
    Frequency,
    Bandwidth,
    SpreadingFactor,
    CodeRate,
    PreambleSymbols,
    ExplicitHeader,
    PayloadLen
) ->
    TimeOnAir = time_on_air(
        Bandwidth,
        SpreadingFactor,
        CodeRate,
        PreambleSymbols,
        ExplicitHeader,
        PayloadLen
    ),
    track_sent(Handle, SentAt, Frequency, TimeOnAir).

-spec track_sent(handle(), number(), number(), number()) -> handle().
track_sent({Region, SentPackets}, SentAt, Frequency, TimeOnAir) ->
    NewSent = #sent_packet{
        frequency = Frequency,
        sent_at = SentAt,
        time_on_air = TimeOnAir
    },
    {Region, trim_sent(Region, [NewSent | SentPackets])}.

-spec trim_sent(region(), list(#sent_packet{})) -> list(#sent_packet{}).
trim_sent(Region, SentPackets = [NewSent, LastSent | _])
        when NewSent#sent_packet.sent_at < LastSent#sent_packet.sent_at ->
    trim_sent(Region, lists:sort(fun (A, B) -> A > B end, SentPackets));
trim_sent('US915', SentPackets = [H | _]) ->
    CutoffTime = H#sent_packet.sent_at - ?DWELL_TIME_PERIOD_MS,
    Pred = fun (Sent) -> Sent#sent_packet.sent_at > CutoffTime end,
    lists:takewhile(Pred, SentPackets);
trim_sent('EU868', SentPackets = [H | _]) ->
    CutoffTime = H#sent_packet.sent_at - ?DUTY_CYCLE_PERIOD_MS,
    Pred = fun (Sent) -> Sent#sent_packet.sent_at > CutoffTime end,
    lists:takewhile(Pred, SentPackets).

%% @doc Based on previously sent packets, returns a boolean value if
%% it is legal to send on Frequency at time Now.
%%
%%
-spec can_send(
    Handle :: handle(),
    AtTime :: number(),
    Frequency :: integer(),
    TimeOnAir :: number()
) ->
    boolean().
can_send(_Handle, _AtTime, _Frequency, TimeOnAir) when TimeOnAir > ?MAX_DWELL_TIME_MS ->
    %% TODO: double check that ETSI's max time on air is the same as
    %% FCC.
    false;
can_send({'US915', SentPackets}, AtTime, Frequency, TimeOnAir) ->
    CutoffTime = AtTime - ?DWELL_TIME_PERIOD_MS + TimeOnAir,
    ProjectedDwellTime = dwell_time(SentPackets, CutoffTime, Frequency) + TimeOnAir,
    ProjectedDwellTime =< ?MAX_DWELL_TIME_MS;
can_send({'EU868', SentPackets}, AtTime, Frequency, TimeOnAir) ->
    CutoffTime = AtTime - ?DUTY_CYCLE_PERIOD_MS,
    CurrDwell = dwell_time(SentPackets, CutoffTime, Frequency),
    OnePercent = 0.01,
    (CurrDwell + TimeOnAir) / ?DUTY_CYCLE_PERIOD_MS < OnePercent.

%% @doc Computes the total time on air for packets sent on Frequency
%% and no older than CutoffTime.
-spec dwell_time(list(#sent_packet{}), integer(), number()) -> number().
dwell_time(SentPackets, CutoffTime, Frequency) ->
    dwell_time(SentPackets, CutoffTime, Frequency, 0).

-spec dwell_time(list(#sent_packet{}), integer(), number(), number()) -> number().
%% Scenario 1: entire packet sent before CutoffTime
dwell_time([P | T], CutoffTime, Frequency, Acc)
        when P#sent_packet.sent_at + P#sent_packet.time_on_air < CutoffTime ->
    dwell_time(T, CutoffTime, Frequency, Acc);
%% Scenario 2: packet sent on non-relevant frequency.
dwell_time([P | T], CutoffTime, Frequency, Acc) when P#sent_packet.frequency /= Frequency ->
    dwell_time(T, CutoffTime, Frequency, Acc);
%% Scenario 3: Packet started before CutoffTime but finished after CutoffTime.
dwell_time([P | T], CutoffTime, Frequency, Acc) when P#sent_packet.sent_at =< CutoffTime ->
    RelevantTimeOnAir = P#sent_packet.time_on_air - (CutoffTime - P#sent_packet.sent_at),
    true = RelevantTimeOnAir >= 0,
    dwell_time(T, CutoffTime, Frequency, Acc + RelevantTimeOnAir);
%% Scenario 4: 100 % of packet transmission after CutoffTime.
dwell_time([P | T], CutoffTime, Frequency, Acc) ->
    dwell_time(T, CutoffTime, Frequency, Acc + P#sent_packet.time_on_air);
dwell_time([], _CutoffTime, _Frequency, Acc) ->
    Acc.

%% @doc Returns total time on air for packet sent with given
%% parameters.
%%
%% See Semtech Appnote AN1200.13, "LoRa Modem Designer's Guide"
-spec time_on_air(
    Bandwidth :: number(),
    SpreadingFactor :: number(),
    CodeRate :: integer(),
    PreambleSymbols :: integer(),
    ExplicitHeader :: boolean(),
    PayloadLen :: integer()
) ->
    Milliseconds :: float().
time_on_air(
    Bandwidth,
    SpreadingFactor,
    CodeRate,
    PreambleSymbols,
    ExplicitHeader,
    PayloadLen
) ->
    SymbolDuration = symbol_duration(Bandwidth, SpreadingFactor),
    PayloadSymbols = payload_symbols(
        SpreadingFactor,
        CodeRate,
        ExplicitHeader,
        PayloadLen,
        (Bandwidth =< 125000) and (SpreadingFactor >= 11)
    ),
    SymbolDuration * (4.25 + PreambleSymbols + PayloadSymbols).

%% @doc Returns the number of payload symbols required to send payload.
-spec payload_symbols(integer(), integer(), boolean(), integer(), boolean()) -> number().
payload_symbols(
    SpreadingFactor,
    CodeRate,
    ExplicitHeader,
    PayloadLen,
    LowDatarateOptimized
) ->
    EH = b2n(ExplicitHeader),
    LDO = b2n(LowDatarateOptimized),
    8 +
        (erlang:max(
            math:ceil(
                (8 * PayloadLen - 4 * SpreadingFactor + 28 +
                    16 - 20 * (1 - EH)) /
                    (4 * (SpreadingFactor - 2 * LDO))
            ) * (CodeRate),
            0
        )).

-spec symbol_duration(number(), number()) -> float().
symbol_duration(Bandwidth, SpreadingFactor) ->
    math:pow(2, SpreadingFactor) / Bandwidth.

%% @doc Returns a new handle for the given region.
-spec new(Region :: region()) -> handle().
new('EU868') ->
    {'EU868', []};
new('US915') ->
    {'US915', []}.

-spec b2n(boolean()) -> integer().
b2n(false) ->
    0;
b2n(true) ->
    1.

dwell_time_period(Unit) ->
    erlang:convert_time_unit(?DWELL_TIME_PERIOD_MS, millisecond, Unit).

max_dwell_time(Unit) ->
    erlang:convert_time_unit(?MAX_DWELL_TIME_MS, millisecond, Unit).
