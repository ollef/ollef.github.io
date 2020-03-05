.PHONY: watch
watch:
	ghcid --run --reload=site

.PHONY: serve
serve:
	yarn run serve

.PHONY: clean
clean:
	rm -r .shake
