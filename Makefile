#
# Copyright (c) 2017 Dmitry Poroh
# All rights reserved.
# Distributed under the terms of the MIT License. See the LICENSE file.
#
# Test run simplification
#

SHELL=/bin/bash

compile:
	@rebar3 compile

clean:
	@rebar3 clean

dialyze:
	@rebar3 dialyzer

xref:
	@rebar3 xref

tests:
	export ERL_FLAGS=$(ERL_FLAGS) ; rebar3 do eunit -v --cover, cover | sed 's/^_build\/test\/lib\/ersip\///' ; exit "$${PIPESTATUS[0]}"
	rebar3 dialyzer
