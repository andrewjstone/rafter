.PHONY: test

rafter:
	./rebar compile
test:
	./rebar eunit skip_deps=true
