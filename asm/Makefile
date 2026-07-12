STAGES := \
	stage0-stack-machine \
	stage1-words \
	stage2-control-flow \
	stage3-memory \
	stage4-forth-in-forth \
	stage5-playground

.PHONY: all clean check $(STAGES)

all: $(STAGES)

$(STAGES):
	$(MAKE) -C $@

check: all
	./check.sh
	./check-errors.sh

clean:
	@for stage in $(STAGES); do $(MAKE) -C $$stage clean; done
