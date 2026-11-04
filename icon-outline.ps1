# Adds a 1px white outline around a PNG icon (baked into the file, so the
# browser doesn't have to draw it with CSS filters on every frame).
Add-Type -AssemblyName System.Drawing

function Add-IconOutline([byte[]]$bytes) {
  $src = [System.Drawing.Bitmap]::new([IO.MemoryStream]::new($bytes))
  $out = [System.Drawing.Bitmap]::new($src.Width + 2, $src.Height + 2)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor

  # White silhouette: keep alpha, force RGB to 1
  $matrix = [System.Drawing.Imaging.ColorMatrix]::new([float[][]]@(
    [float[]](0, 0, 0, 0, 0), [float[]](0, 0, 0, 0, 0), [float[]](0, 0, 0, 0, 0),
    [float[]](0, 0, 0, 1, 0), [float[]](1, 1, 1, 0, 1)))
  $attrs = [System.Drawing.Imaging.ImageAttributes]::new()
  $attrs.SetColorMatrix($matrix)

  foreach ($dx in 0..2) { foreach ($dy in 0..2) {
    if ($dx -eq 1 -and $dy -eq 1) { continue }
    $rect = [System.Drawing.Rectangle]::new($dx, $dy, $src.Width, $src.Height)
    $g.DrawImage($src, $rect, 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
  } }
  $g.DrawImage($src, 1, 1, $src.Width, $src.Height)

  $ms = [IO.MemoryStream]::new()
  $out.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $out.Dispose(); $src.Dispose(); $attrs.Dispose()
  return $ms.ToArray()
}
