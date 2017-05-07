VERSION := $(shell jq -r .version info.json)
NAME := $(shell jq -r .name info.json)
ZIPFILE := $(NAME)_$(VERSION).zip
PATH := $(shell luarocks path --lr-bin):$(PATH)
export PATH

INTERACTIVE := $(shell exec 3>/proc/$$PPID/fd/1 && [ -t 3 ] && echo 1)
LUACHECK := luacheck

ifneq ($(INTERACTIVE),1)
	LUACHECKOPTS += --no-color
endif


zip: test $(ZIPFILE)

$(ZIPFILE): info.json
	rm -f $@
	rm -rf $(NAME)_$(VERSION)
	mkdir $(NAME)_$(VERSION)
	cp $^ $(NAME)_$(VERSION)
	zip -r $@ $(NAME)_$(VERSION)
	rm -rf $(NAME)_$(VERSION)

.PHONY: deps
deps:
	luarocks --local install luacheck

test:
	$(LUACHECK) $(LUACHECKOPTS) ./*.lua
