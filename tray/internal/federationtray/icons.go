package federationtray

import (
	"bytes"
	"image"
	"image/color"
	"image/draw"
	"image/png"
)

// IconPNG creates small placeholder PNGs without a GUI toolkit or an asset
// pipeline. The simple shapes make the four states distinguishable until
// product artwork replaces them.
func IconPNG(state VisualState) []byte {
	canvas := image.NewNRGBA(image.Rect(0, 0, 32, 32))
	fill := color.NRGBA{R: 105, G: 117, B: 132, A: 255}
	switch state {
	case VisualActive:
		fill = color.NRGBA{R: 34, G: 197, B: 94, A: 255}
	case VisualAttention:
		fill = color.NRGBA{R: 245, G: 158, B: 11, A: 255}
	case VisualSetup:
		fill = color.NRGBA{R: 96, G: 165, B: 250, A: 255}
	}
	drawCircle(canvas, 16, 16, 13, fill)
	if state == VisualIdle {
		draw.Draw(canvas, image.Rect(11, 9, 14, 23), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
		draw.Draw(canvas, image.Rect(18, 9, 21, 23), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
	}
	if state == VisualAttention {
		draw.Draw(canvas, image.Rect(14, 8, 18, 19), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
		draw.Draw(canvas, image.Rect(14, 22, 18, 26), &image.Uniform{C: color.White}, image.Point{}, draw.Src)
	}
	if state == VisualSetup {
		drawCircle(canvas, 16, 16, 5, color.NRGBA{R: 255, G: 255, B: 255, A: 255})
	}
	var encoded bytes.Buffer
	_ = png.Encode(&encoded, canvas)
	return encoded.Bytes()
}

func drawCircle(canvas *image.NRGBA, centerX, centerY, radius int, fill color.NRGBA) {
	for y := centerY - radius; y <= centerY+radius; y++ {
		for x := centerX - radius; x <= centerX+radius; x++ {
			deltaX, deltaY := x-centerX, y-centerY
			if deltaX*deltaX+deltaY*deltaY <= radius*radius {
				canvas.SetNRGBA(x, y, fill)
			}
		}
	}
}
