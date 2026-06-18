define n


endef

.EXPORT_ALL_VARIABLES:

NAME=StartupFolder
BETA=
DELTAS=5

ifeq (, $(VERSION))
VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1 | sd 'b\d+' '')
endif

ifneq (, $(BETA))
FULL_VERSION:=$(VERSION)b$(BETA)
else
FULL_VERSION:=$(VERSION)
endif

RELEASE_NOTES_FILES := $(wildcard ReleaseNotes/*.md)
ENV=Release
DERIVED_DATA_DIR=$(shell ls -td $$HOME/Library/Developer/Xcode/DerivedData/$(NAME)-* | head -1)

.PHONY: build upload release setversion appcast

print-%  : ; @echo $* = $($*)

build: SHELL=fish
build:
	make-app --build --devid --dmg -s $(NAME) -t $(NAME) -c Release --version $(FULL_VERSION)
	xcp /tmp/apps/$(NAME)-$(FULL_VERSION).dmg Releases/

dmg: SHELL=fish
dmg:
	make-app --dmg -s $(NAME) -t $(NAME) -c Release --version $(FULL_VERSION) /tmp/apps/$(NAME).app
	xcp /tmp/apps/$(NAME)-$(FULL_VERSION).dmg Releases/

upload:
	rsync -avzP Releases/*.{delta,dmg} hetzner:/static/lowtechguys/releases/ || true
	rsync -avz Releases/*.html hetzner:/static/lowtechguys/ReleaseNotes/
	rsync -avzP Releases/appcast.xml hetzner:/static/lowtechguys/startupfolder/
	cfcli -d lowtechguys.com purge

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/$(NAME)-$(VERSION).dmg#$(NAME).dmg"
	git fetch --tags

sentry:
	op run -- sentry-cli upload-dif --include-sources -o alin-panaitiu -p startupfolder --wait -- $(DERIVED_DATA_DIR)/Build/Intermediates.noindex/ArchiveIntermediates/$(NAME)/BuildProductsPath/Release/

appcast: Releases/$(NAME)-$(FULL_VERSION).html
	rm Releases/$(NAME).dmg || true
ifneq (, $(BETA))
	rm Releases/$(NAME)$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	generate_appcast --channel beta --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/startupfolder" --full-release-notes-url "https://github.com/FuzzyIdeas/$(NAME)/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
else
	rm Releases/$(NAME)$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	rm Releases/$(NAME)-*b*.dmg >/dev/null 2>/dev/null || true
	rm Releases/$(NAME)*b*.delta >/dev/null 2>/dev/null || true
	generate_appcast --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/startupfolder" --full-release-notes-url "https://github.com/FuzzyIdeas/$(NAME)/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
	cp Releases/$(NAME)-$(FULL_VERSION).dmg Releases/$(NAME).dmg
endif


setversion: OLD_VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1)
setversion: SHELL=fish
setversion:
ifneq (, $(FULL_VERSION))
	sdfk '((?:CURRENT_PROJECT|MARKETING)_VERSION) = $(OLD_VERSION);' '$$1 = $(FULL_VERSION);'
endif

Releases/$(NAME)-%.html: ReleaseNotes/$(VERSION)*.md
	@echo Compiling $^ to $@
ifneq (, $(BETA))
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="$(NAME) $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css $(shell ls -t ReleaseNotes/$(VERSION)*.md)
else
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="$(NAME) $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css ReleaseNotes/$(VERSION).md
endif
