FROM jekyll/jekyll:pages

VOLUME [ "/srv/jekyll" ]

#  --volume=C:\Users\Nick\dev\nickwilcox.github.io:/srv/jekyll  -it -p 4000:4000 jekyll/jekyll:pages jekyll serve --watch

EXPOSE 4000

ENTRYPOINT [ "jekyll", "serve", "--watch", "--drafts" ]