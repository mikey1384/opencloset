SET NAMES utf8;

DROP DATABASE `opencloset`;
CREATE DATABASE `opencloset`;
USE `opencloset`;

--
-- donor 기증자
--

CREATE TABLE `donor` (
  `id`   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(32) NOT NULL,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- guest
--

CREATE TABLE `guest` (
  `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name`       VARCHAR(32) NOT NULL,
  `email`      VARCHAR(128) DEFAULT NULL,
  `phone`      VARCHAR(16) DEFAULT NULL COMMENT 'regex: [0-9]{10,11}',
  `gender`     INT DEFAULT NULL,
  `address`    VARCHAR(255) DEFAULT NULL,
  `birth_date` DATETIME DEFAULT NULL,
  `purpose`    VARCHAR(32),
  `d_date`     DATETIME DEFAULT NULL,

  `chest`      INT NOT NULL,     -- 가슴둘레(cm)
  `waist`      INT NOT NULL,     -- 허리둘레(cm)
  `arm`        INT DEFAULT NULL, -- 팔길이(cm)
  `pants_len`  INT DEFAULT NULL, -- 기장(cm)
  `height`     INT DEFAULT NULL, -- cm
  `weight`     INT DEFAULT NULL, -- kg

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- category
--

CREATE TABLE `category` (
  `id`   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name` VARCHAR (64) NOT NULL,

  PRIMARY KEY (`id`),
  UNIQUE KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO `category` (`id`, `name`) VALUES (1, 'Jacket'), (2, 'Pants'), (3, 'Shirts'), (4, 'Shoes'), (5, 'Hat');

--
-- status
--

CREATE TABLE `status` (
  `id`   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name` VARCHAR (64) NOT NULL,

  PRIMARY KEY (`id`),
  UNIQUE KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO `status` (`id`, `name`) VALUES (1, '대여가능'), (2, '대여중'), (3, '세탁'), (4, '수선'), (5, '대여불가'), (6, '분실');

--
-- clothes
--

CREATE TABLE `clothes` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `no`          VARCHAR(64) NOT NULL,  -- 바코드 품번
  `chest`       INT DEFAULT NULL,
  `waist`       INT DEFAULT NULL,
  `arm`         INT DEFAULT NULL, -- 팔길이(cm)
  `pants_len`   INT DEFAULT NULL, -- 기장(cm)

  `category_id` INT UNSIGNED NOT NULL,
  `top_id`      INT UNSIGNED DEFAULT NULL,
  `bottom_id`   INT UNSIGNED DEFAULT NULL,
  `donor_id`    INT UNSIGNED DEFAULT NULL,
  `status_id`   INT UNSIGNED DEFAULT 1,

  PRIMARY KEY (`id`),
  UNIQUE KEY (`no`),
  CONSTRAINT `fk_clothes1` FOREIGN KEY (`category_id`) REFERENCES `category` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_clothes2` FOREIGN KEY (`top_id`) REFERENCES `clothes` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_clothes3` FOREIGN KEY (`bottom_id`) REFERENCES `clothes` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_clothes4` FOREIGN KEY (`donor_id`) REFERENCES `donor` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_clothes5` FOREIGN KEY (`status_id`) REFERENCES `status` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- satisfaction
--

CREATE TABLE `satisfaction` (
  -- 1: 매우작음, 2: 매우큼, 3: 작음, 4: 큼, 5: 맞음
  -- 높을 수록 좋은거(작은거 보단 큰게 낫다 by aanoaa)
  -- 쟈켓만 해당함

  `guest_id`   INT UNSIGNED NOT NULL,
  `clothes_id` INT UNSIGNED NOT NULL,
  `chest`      INT DEFAULT NULL,
  `waist`      INT DEFAULT NULL,
  `arm`        INT DEFAULT NULL,
  `top_fit`    INT DEFAULT NULL,
  `bottom_fit` INT DEFAULT NULL,

  PRIMARY KEY (`guest_id`, `clothes_id`),
  CONSTRAINT `fk_satisfaction1` FOREIGN KEY (`guest_id`) REFERENCES `guest` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_satisfaction2` FOREIGN KEY (`clothes_id`) REFERENCES `clothes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- order
--

CREATE TABLE `order` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `guest_id`    INT UNSIGNED NOT NULL,

  `rental_date` DATETIME DEFAULT NULL,
  `target_date` DATETIME DEFAULT NULL,
  `return_date` DATETIME DEFAULT NULL,
  `price`       INT DEFAULT 0,
  `discount`    INT DEFAULT 0,
  `comment`     TEXT DEFAULT NULL,

  PRIMARY KEY (`id`),
  CONSTRAINT `fk_order1` FOREIGN KEY (`guest_id`) REFERENCES `guest` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- clothes_order
--

CREATE TABLE `clothes_order` (
  `clothes_id` INT UNSIGNED NOT NULL,
  `order_id`   INT UNSIGNED NOT NULL,

  PRIMARY KEY (`clothes_id`, `order_id`),
  CONSTRAINT `fk_clothes_order1` FOREIGN KEY (`clothes_id`) REFERENCES `clothes` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_clothes_order2` FOREIGN KEY (`order_id`) REFERENCES `order` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- donor_clothes
--

CREATE TABLE `donor_clothes` (
  `donor_id`      INT UNSIGNED NOT NULL,
  `clothes_id`    INT UNSIGNED NOT NULL,
  `comment`       TEXT DEFAULT NULL,
  `donation_date` DATETIME DEFAULT NULL,

  PRIMARY KEY (`donor_id`, `clothes_id`),
  CONSTRAINT `fk_donor_clothes1` FOREIGN KEY (`donor_id`) REFERENCES `donor` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_donor_clothes2` FOREIGN KEY (`clothes_id`) REFERENCES `clothes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
