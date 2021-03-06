has_state_time <- function(x, ...) {
  UseMethod("has_state_time")
}

#' @export
has_state_time.uneval_matrix <- function(x, ...) {
  unlist(lapply(x, function(y) "state_time" %in% all.vars(y$expr)))
}

has_state_time.uneval_parameters <- function(x, ...) {
  unlist(lapply(x, function(y) "state_time" %in% all.vars(y$expr)))
}

#' @export
has_state_time.part_surv <- function(x, ...) {
  FALSE
}

#' @export
has_state_time.uneval_state_list <- function(x, ...) {
  unlist(lapply(x, has_state_time))
}

#' @export
has_state_time.state <- function(x, ...) {
  any(unlist(lapply(x$.dots, function(y) "state_time" %in% all.vars(y$expr))))
}

substitute_dots <- function(.dots, .values) {
  lazyeval::as.lazy_dots(
    lapply(.dots, lazyeval::interp, .values = .values)
  )
}

#' Expand Time-Dependant States into Tunnel States
#' 
#' This function for transition matrices and state values 
#' expands states relying on `state_time` in a serie
#' of tunnels states.
#' 
#' @param x A transition matrix or a state list.
#' @param state_pos Position of the state to expand.
#' @param state_name Original name of the sate to expand.
#' @param cycles Number of cycle of the model.
#' @param n Postition in the expansion process.
#' @param ... Addition parameters passed to methods.
#'   
#' @return The same object type as the input.
#' @keywords internal
expand_state <- function(x, ...) {
  UseMethod("expand_state")
}

#' @export
#' @rdname expand_state
expand_state.uneval_matrix <- function(x, state_pos,
                                       state_name, cycles, n = 1) {
  L <- length(x)
  N <- sqrt(L)
  
  if (n <= cycles) {
    # positions to insert 0
    i <- seq(0, L - 1, N) + state_pos
    i[state_pos] <- i[state_pos] - 1
    res <- insert(x, i, list(lazyeval::lazy(0)))
    
    # row to duplicate
    new <- res[seq(
      from = get_tm_pos(state_pos, 1, N+1),
      to = get_tm_pos(state_pos, N+1, N+1))]
    
    # edit state_time
    new <- substitute_dots(new, list(state_time = n))
    
    # and reinsert
    res <- insert(res, (N+1)*(state_pos-1),
                  new)
    
    sn <- get_state_names(x)
    sn[state_pos] <- sprintf(".%s_%i", state_name, n)
    sn <- insert(sn, state_pos, sprintf(".%s_%i", state_name, n + 1))
    
    tm_ext <- define_transition_(res, sn)
    
    expand_state(
      x = tm_ext,
      state_pos = state_pos + 1,
      state_name = state_name,
      n = n + 1,
      cycles = cycles
    )
  } else {
    x[get_tm_pos(state_pos, 1, N):get_tm_pos(state_pos, N, N)] <-
      substitute_dots(
        x[get_tm_pos(state_pos, 1, N):get_tm_pos(state_pos, N, N)],
        list(state_time = n)
      )
    x
  }
}

#' @export
#' @rdname expand_state
expand_state.uneval_state_list <- function(x, state_name, cycles) {
  
  st <- x[[state_name]]
  x[state_name] <- NULL
  state_values_names <- get_state_value_names(st)
  num_state_values <-length(state_values_names)
  revert_starting <- setNames(as.list(rep(0, num_state_values)), state_values_names) %>%
    as.lazy_dots()
  
  id <- seq_len(cycles + 1)
  res <- lapply(
    id,
    function(i) {
      list(
        .dots = substitute_dots(st$.dots, list(state_time = i)),
        starting_values = if (i == 1) {
          substitute_dots(st$starting_values, list(state_time = i))
        } else {
          revert_starting
        }
      )
    }
  )
  names(res) <- sprintf(".%s_%i", state_name, id)
  
  structure(
    c(x, res),
    class = class(x)
  )
}

#' @export
#' @rdname expand_state
expand_state.uneval_inflow <- function(x, ...) {
  expand_state.uneval_init(x, ...)
}

#' @export
#' @rdname expand_state
expand_state.uneval_init <- function(x, state_name, cycles) {
  res <- insert(
    x,
    which(names(x) == state_name),
    stats::setNames(
      rep(list(lazyeval::lazy(0)), cycles),
      sprintf(".%s_%i", state_name, seq_len(cycles) + 1))
  )
  
  names(res)[which(names(res) == state_name)] <- sprintf(".%s_1", state_name)
  structure(res, class = class(x))
}

#' Convert Lazy Dots to Expression List
#' 
#' This function is used by [interpolate()].
#'
#' @param .dots A lazy dots object.
#'
#' @return A list of expression.
#' @keywords internal
as_expr_list <- function(.dots) {
  setNames(
    lapply(.dots, function(x) x$expr),
    names(.dots)
  )
}

#' Interpolate Lazy Dots
#' 
#' Sequentially interpolates lazy dots, optionally using 
#' external references.
#' 
#' The interpolation is sequential: the second dot is 
#' interpolated using the first, the third using the 
#' interpolated first two, and so on.
#' 
#' @param x A parameter, transition matrix or state list
#'   object.
#' @param more A list of expressions.
#' @param ... Addition parameters passed to methods.
#'   
#' @return An interpolated lazy dots object.
#' @keywords internal
interpolate <- function(x, ...) {
  UseMethod("interpolate")
}

#' @export
#' @rdname interpolate
interpolate.default <- function(x, more = NULL, ...) {
  res <- NULL
  
  for (i in seq_along(x)) {
    to_interp <- x[[i]]
    for_interp <- c(more, as_expr_list(res))
    funs <- all.funs(to_interp$expr)
    
    if (any(pb <- funs %in% names(for_interp))) {
      stop(sprintf(
        "Some parameters are named like a function, this is incompatible with the use of 'state_time': %s.",
        paste(funs[pb], collapse = ", ")
      ))
    }
    
    new <- setNames(list(lazyeval::interp(
      to_interp,
      .values = for_interp
    )
    ), names(x)[i])
    res <- c(res, new)
    
  }
  lazyeval::as.lazy_dots(res)
}


#' @export
#' @rdname interpolate
interpolate.uneval_matrix <- function(x, ...) {
  res <- interpolate.default(x, ...)
  define_transition_(res, get_state_names(x))
}

#' @export
#' @rdname interpolate
interpolate.state <- function(x, ...) {
  res <- structure(
    list(
    .dots = interpolate.default(x$.dots, ...),
    starting_values = x$starting_values
    )
  )
  define_state_(res)
}

#' @export
#' @rdname interpolate
interpolate.part_surv <- function(x, ...) {
  x
}

#' @export
#' @rdname interpolate
interpolate.uneval_state_list <- function(x, ...) {
  for (i in seq_along(x)) {
    # y <- structure(x[[i]]$.dots,
    #                class = class(x[[i]]))
    #x[[i]] <- interpolate(y, ...)
    x[[i]] <- interpolate(x[[i]], ...)
  }
  x
}

all.funs <- function(expr) {
  with_funs <- table(all.names(expr))
  without_funs <- table(all.names(expr, functions = FALSE))
  
  with_funs[names(without_funs)] <-
    with_funs[names(without_funs)] -
    without_funs
  names(with_funs)[with_funs > 0]
}

complete_stl <- function(scl, state_names,
                         strategy_names, cycles) {
  uni <- FALSE
  if (is.numeric(scl) && length(scl) == 1 && is.null(names(scl))) {
    uni <- TRUE
    stopifnot(
      scl <= cycles,
      scl > 0,
      ! is.na(scl),
      is.wholenumber(scl)
    )
    cycles <- scl
  }
  
  res <- lapply(
    strategy_names,
    function(x) rep(cycles, length(state_names)) %>% 
      setNames(state_names)
  ) %>% 
    setNames(strategy_names)
  
  if (is.null(scl) || uni) {
    return(res)
  }
  
  check_scl <- function(scl, cycles) {
    if (is.null(names(scl))) {
      stop("'state_time_limit' must be named.")
    }
    if (any(duplicated(names(scl)))) {
      stop("'state_time_limit' names must be unique.")
    }
    if (any(pb <- ! names(scl) %in% state_names)) {
      stop(sprintf(
        "Some 'state_time_limit' names are not state names: %s.",
        paste(names(scl)[pb], collapse = ", ")
      ))
    }
    
    stopifnot(
      ! is.na(scl),
      scl > 0,
      scl <= cycles,
      is.wholenumber(scl)
    )
  }
  
  if (is.numeric(scl)) {
    check_scl(scl, cycles)
    for (i in seq_along(res)) {
      res[[i]][names(scl)] <- scl
    }
    return(res)
  }
  
  if (is.list(scl)) {
    if (any(pb <- ! names(scl) %in% strategy_names)) {
      stop(sprintf(
        "Some 'state_limit_cycle' names are not model names: %s.",
        paste(names(scl)[pb], collapse = ", ")
      ))
    }
    for (n in names(scl)) {
      check_scl(scl[[n]], cycles)
      
      res[[n]][names(scl[[n]])] <- scl[[n]]
    }
    return(res)
  }
  
  stop("'Incorrect 'state_time_limit' type.")
}
