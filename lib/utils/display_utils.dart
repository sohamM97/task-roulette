String displayUrl(String url, {int maxLength = 40}) {
  var display = url.replaceFirst(RegExp(r'^https?://'), '');
  if (display.endsWith('/')) display = display.substring(0, display.length - 1);
  return display.length > maxLength ? '${display.substring(0, maxLength)}...' : display;
}
