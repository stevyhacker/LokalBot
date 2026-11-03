//! Sizes a picture for EmbeddingGemma 2's vision encoder the way the model's
//! reference processor does (`FileImageSizing`, from DigUp's `ImageSizing`, MIT),
//! so the media embedder sees the pixels the reference vectors were made from.
//!
//! The media embedder runs with `--image-min-tokens 1 --image-max-tokens 1120`,
//! so llama.cpp never rescales an image that already has its final size: each
//! image's token budget is set here.

/// Soft-token budgets the encoder accepts.
pub const BUDGETS: [u32; 5] = [70, 140, 280, 560, 1120];

/// Packed 8-bit RGB in memory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rgb {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

/// transformers' Gemma 4 image processor: scale to fill `budget` soft tokens
/// (each 3 × 3 patches of 16 px) keeping the aspect ratio, each side rounded
/// down to a multiple of 48 px. `None` for an image with no area.
pub fn target_size(height: usize, width: usize, budget: u32) -> Option<(usize, usize)> {
    if height == 0 || width == 0 {
        return None;
    }
    const PATCH: usize = 16;
    const POOLING: usize = 3;
    let max_patches = budget as usize * POOLING * POOLING;
    let factor = ((max_patches * PATCH * PATCH) as f64 / (height * width) as f64).sqrt();
    let side = POOLING * PATCH;
    let mut target_height = (factor * height as f64 / side as f64).floor() as usize * side;
    let mut target_width = (factor * width as f64 / side as f64).floor() as usize * side;
    if target_height == 0 && target_width == 0 {
        return None;
    }
    let max_side = (max_patches / (POOLING * POOLING)) * side;
    if target_height == 0 {
        target_height = side;
        target_width = (width / height * side).min(max_side);
    } else if target_width == 0 {
        target_width = side;
        target_height = (height / width * side).min(max_side);
    }
    Some((target_height, target_width))
}

/// The picture resized for `budget`, encoded as a PNG. Nothing is written to
/// disk, so a decrypted screen capture stays in memory.
pub fn png(image: &Rgb, budget: u32) -> Result<Vec<u8>, String> {
    if !BUDGETS.contains(&budget) {
        return Err(format!("unsupported budget {budget}"));
    }
    let (height, width) =
        target_size(image.height, image.width, budget).ok_or("a picture with no area")?;
    let sized;
    let pixels: &[u8] = if (height, width) == (image.height, image.width) {
        &image.pixels
    } else {
        sized = resize_bicubic(&image.pixels, image.width, image.height, width, height);
        &sized
    };
    encode_png(pixels, width, height)
}

fn encode_png(rgb: &[u8], width: usize, height: usize) -> Result<Vec<u8>, String> {
    use image::ImageEncoder as _;
    let mut out = Vec::new();
    image::codecs::png::PngEncoder::new(&mut out)
        .write_image(
            rgb,
            width as u32,
            height as u32,
            image::ExtendedColorType::Rgb8,
        )
        .map_err(|err| err.to_string())?;
    Ok(out)
}

const PRECISION: i32 = 22;

fn filter(value: f64) -> f64 {
    let x = value.abs();
    let a = -0.5;
    if x < 1.0 {
        ((a + 2.0) * x - (a + 3.0)) * x * x + 1.0
    } else if x < 2.0 {
        (((x - 5.0) * x + 8.0) * x - 4.0) * a
    } else {
        0.0
    }
}

/// For each output pixel: the first contributing input pixel, how many
/// contribute, and their weights.
fn coefficients(in_size: usize, out_size: usize) -> (Vec<usize>, Vec<i32>, usize) {
    let scale = in_size as f64 / out_size as f64;
    let filter_scale = scale.max(1.0);
    let support = 2.0 * filter_scale;
    let size = support.ceil() as usize * 2 + 1;
    let mut bounds = vec![0usize; out_size * 2];
    let mut weights = vec![0i32; out_size * size];
    let mut row = vec![0f64; size];
    for out in 0..out_size {
        let center = (out as f64 + 0.5) * scale;
        let first = ((center - support + 0.5) as i64).max(0) as usize;
        let count = (((center + support + 0.5) as i64).min(in_size as i64) as usize) - first;
        let mut total = 0.0;
        for (x, slot) in row.iter_mut().enumerate() {
            *slot = if x < count {
                filter(((x + first) as f64 - center + 0.5) / filter_scale)
            } else {
                0.0
            };
            total += *slot;
        }
        for (x, value) in row.iter().enumerate() {
            let weight = if x < count && total != 0.0 {
                value / total
            } else {
                *value
            };
            let rounding = if weight < 0.0 { -0.5 } else { 0.5 };
            weights[out * size + x] = (weight * (1i64 << PRECISION) as f64 + rounding) as i32;
        }
        bounds[out * 2] = first;
        bounds[out * 2 + 1] = count;
    }
    (bounds, weights, size)
}

fn clip(value: i32) -> u8 {
    (value >> PRECISION).clamp(0, 255) as u8
}

/// Pillow's bicubic resampling of packed RGB (a = −0.5, the kernel widened when
/// shrinking, 22-bit fixed point): what the reference gets from `Image.resize`.
pub fn resize_bicubic(
    source: &[u8],
    width: usize,
    height: usize,
    to_width: usize,
    to_height: usize,
) -> Vec<u8> {
    match (to_width != width, to_height != height) {
        (true, true) => {
            let pass = horizontal(source, width, height, to_width);
            vertical(&pass, height, to_width, to_height)
        }
        (true, false) => horizontal(source, width, height, to_width),
        (false, true) => vertical(source, height, width, to_height),
        (false, false) => source.to_vec(),
    }
}

fn horizontal(source: &[u8], in_width: usize, rows: usize, out_width: usize) -> Vec<u8> {
    let (bounds, weights, size) = coefficients(in_width, out_width);
    let mut out = vec![0u8; out_width * rows * 3];
    for y in 0..rows {
        for x in 0..out_width {
            let mut pixel = (y * in_width + bounds[x * 2]) * 3;
            let half = 1i32 << (PRECISION - 1);
            let (mut red, mut green, mut blue) = (half, half, half);
            for k in 0..bounds[x * 2 + 1] {
                let weight = weights[x * size + k];
                red = red.wrapping_add((source[pixel] as i32).wrapping_mul(weight));
                green = green.wrapping_add((source[pixel + 1] as i32).wrapping_mul(weight));
                blue = blue.wrapping_add((source[pixel + 2] as i32).wrapping_mul(weight));
                pixel += 3;
            }
            let offset = (y * out_width + x) * 3;
            out[offset] = clip(red);
            out[offset + 1] = clip(green);
            out[offset + 2] = clip(blue);
        }
    }
    out
}

fn vertical(source: &[u8], in_height: usize, row_width: usize, out_height: usize) -> Vec<u8> {
    let (bounds, weights, size) = coefficients(in_height, out_height);
    let stride = row_width * 3;
    let mut out = vec![0u8; stride * out_height];
    let mut sums = vec![0i32; stride];
    for y in 0..out_height {
        sums.fill(1i32 << (PRECISION - 1));
        for k in 0..bounds[y * 2 + 1] {
            let row = (bounds[y * 2] + k) * stride;
            let weight = weights[y * size + k];
            for (i, sum) in sums.iter_mut().enumerate() {
                *sum = sum.wrapping_add((source[row + i] as i32).wrapping_mul(weight));
            }
        }
        for (i, sum) in sums.iter().enumerate() {
            out[y * stride + i] = clip(*sum);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_zero_sided_image_has_no_target_size() {
        assert_eq!(target_size(0, 1440, 140), None);
        assert_eq!(target_size(900, 0, 140), None);
    }

    #[test]
    fn target_size_fills_the_budget() {
        assert_eq!(target_size(900, 1440, 280), Some((624, 1008)));
        assert_eq!(target_size(900, 1440, 140), Some((432, 672)));
        assert_eq!(target_size(900, 1440, 70), Some((288, 480)));
        assert_eq!(target_size(768, 768, 280), Some((768, 768)));
        assert_eq!(target_size(768, 768, 140), Some((528, 528)));
        // Small images grow to fill the budget, as in the reference.
        assert_eq!(target_size(300, 300, 140), Some((528, 528)));
        // One side rounds to zero: one 48 px row, the other capped at the budget.
        assert_eq!(target_size(10, 4000, 140), Some((48, 6720)));
    }

    /// A 7×5 image resized by PIL (`Image.resize`, BICUBIC). The fixtures are
    /// DigUp's, as `FileImageSizingTests` uses them.
    const SOURCE: [u8; 105] = [
        0, 115, 230, 3, 118, 233, 6, 121, 236, 9, 124, 239, 12, 127, 242, 15, 130, 245, 18, 133,
        248, 77, 192, 51, 80, 195, 54, 83, 198, 57, 86, 201, 60, 89, 204, 63, 92, 207, 66, 95, 210,
        69, 154, 13, 128, 157, 16, 131, 160, 19, 134, 163, 22, 137, 166, 25, 140, 169, 28, 143,
        172, 31, 146, 231, 90, 205, 234, 93, 208, 237, 96, 211, 240, 99, 214, 243, 102, 217, 246,
        105, 220, 249, 108, 223, 52, 167, 26, 55, 170, 29, 58, 173, 32, 61, 176, 35, 64, 179, 38,
        67, 182, 41, 70, 185, 44,
    ];

    #[test]
    fn shrinking_matches_pillow() {
        let pil: [u8; 36] = [
            28, 151, 152, 33, 156, 157, 39, 162, 163, 44, 167, 168, 165, 68, 129, 170, 73, 134,
            176, 79, 140, 181, 84, 145, 132, 133, 106, 137, 138, 111, 143, 144, 117, 148, 149, 122,
        ];
        assert_eq!(resize_bicubic(&SOURCE, 7, 5, 4, 3), pil);
    }

    #[test]
    fn growing_matches_pillow() {
        let pil: [u8; 180] = [
            0, 112, 237, 0, 113, 238, 1, 116, 241, 3, 118, 243, 5, 120, 245, 7, 122, 247, 9, 124,
            249, 11, 126, 251, 14, 129, 254, 15, 130, 255, 55, 187, 85, 56, 188, 86, 59, 191, 89,
            61, 193, 91, 63, 195, 93, 65, 197, 95, 67, 199, 97, 69, 201, 99, 72, 204, 102, 73, 205,
            103, 122, 82, 83, 123, 83, 84, 126, 86, 87, 128, 88, 89, 130, 90, 91, 132, 92, 93, 134,
            94, 95, 136, 96, 97, 139, 99, 100, 140, 100, 101, 199, 27, 173, 200, 28, 174, 203, 31,
            177, 205, 33, 179, 207, 35, 181, 209, 37, 183, 211, 39, 185, 213, 41, 187, 216, 44,
            190, 217, 45, 191, 197, 112, 171, 198, 113, 172, 201, 116, 175, 203, 118, 177, 205,
            120, 179, 207, 122, 181, 209, 124, 183, 211, 126, 185, 214, 129, 188, 215, 130, 189,
            45, 170, 19, 46, 171, 20, 49, 174, 23, 51, 176, 25, 53, 178, 27, 55, 180, 29, 57, 182,
            31, 59, 184, 33, 62, 187, 36, 63, 188, 37,
        ];
        assert_eq!(resize_bicubic(&SOURCE, 7, 5, 10, 6), pil);
    }

    #[test]
    fn the_same_size_keeps_the_pixels() {
        assert_eq!(resize_bicubic(&SOURCE, 7, 5, 7, 5), SOURCE);
    }

    #[test]
    fn pngs_have_their_budgets_size() {
        let image = Rgb {
            width: 768,
            height: 768,
            pixels: vec![100; 768 * 768 * 3],
        };
        let bytes = png(&image, 140).unwrap();
        let decoded = image::load_from_memory(&bytes).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (528, 528));
        assert_eq!(decoded.to_rgb8().as_raw()[0], 100);
        assert!(png(&image, 333).is_err());
    }
}
