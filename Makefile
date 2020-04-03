.PHONY: watch
watch:
	stack exec --package ghcid -- ghcid --run --reload=site

.PHONY: serve
serve:
	yarn
	yarn run serve

.PHONY: clean
clean:
	rm -r .shake
